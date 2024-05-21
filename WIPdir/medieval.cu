#include <stdio.h>
#include <stdlib.h>
#include <iostream>
#include <sstream>
#include <fstream>
#include <algorithm>
#include <vector>





struct Network {
    // Handled by srcKernel
    int sourceCnt;              // number of source nodes
    int* sourceIDs;             // sourceIDs[i] = ID of the i-th source node
    int* sourceBits;            // decimal-formatted source vals for k-th cycle are found through indices: k*sourceCnt -> (k+1)*sourceCnt-1

    // Handled by genKernel
    int nodeCnt;                // number of nodes
    int edgeCnt;                // number of edges
    int colCnt;                 // number of columns
    int lutCnt;                 // number of LUTs
    int regCnt;                 // number of registers
    int* offsets;               // offsets[i] = prefix sum of #prevNodes from node 0 to i-1, inclusive
    int* csr;                   // i-th node's prevNode IDs are found:     csr[offs[i]] -> csr[offs[i+1]-1]
    int* typeIDs;               // typeIDs[i] = n where node with ID i is the n-th input, LUT, or register, 0-indexed (to get INP/LUT/REG-ID given nodeID)
    int* regIndicator;          // regIndicator[i] = 1 if node @ ID i is a register, 0 otherwise.
    int* regBuffer;             // regBuffer[i] = regID i register's oldGen val before being touched by genKernel, newGen val after being touched.
    int* lutOffsets;            // lutOffs[i] = prefix sum of #ints-needed-to-represent-LUT-control-bits from LUT 0 to i-1, inclusive (offsets for the lutBits-CSR).
    unsigned int* lutBits;      // i-th LUT's lutbits (decimal-formatted) are found:         lutBits[lutOffsets[i]] -> lutBits[lutOffsets[i+1]-1]
    int* outputBits;            // decimal-formatted output vals for k-th cycle are found through indices: k*nodeCnt -> (k+1)*nodeCnt-1
    int* colIdxs;               // colIdxs[i] = prefix sum of column-nodecounts from col 0 to i-1, inclusive
    int* colIDs;                // i-th column's nodeIDs are found:        colIDs[colIdxs[i]] -> colIDs[colIdxs[i+1]-1]

    Network(int srcCnt, int* srcIDs, int* srcBts, int ndCnt, int edgCnt, int colCnt, int lutCnt, int regCnt, int* offs, int* csr,
            int* tpIDs, int* regInd, int* regBuf, int* lutOffs, unsigned int* lutBts, int* outBts, int* colIdxs, int* colIDs)
       : sourceCnt(srcCnt),
         sourceIDs(srcIDs),
         sourceBits(srcBts),
         nodeCnt(ndCnt),
         edgeCnt(edgCnt),
         colCnt(colCnt),
         lutCnt(lutCnt),
         regCnt(regCnt),
         offsets(offs),
         csr(csr),
         typeIDs(tpIDs),
         regIndicator(regInd),
         regBuffer(regBuf),
         lutOffsets(lutOffs),
         lutBits(lutBts),
         outputBits(outBts),
         colIdxs(colIdxs),
         colIDs(colIDs) {}
};


int comparator(const void *a, const void *b) {
    return ((const int (*)[2])a)[0][0] - ((const int (*)[2])b)[0][0];
}

// This csr-reversal function WILL NOT preserve the order of dependencies (matters to LUT computation)
void gen_outgoing_csr(Network ntwk, int* out_offs, int* out_csr) {
    // Form tuples of all (srcID, dstID) connexions from the graph
    int tupleCnt = 0;
    int tuples[ntwk.edgeCnt][2];         // k-th tuple located at: (tuples[k][0], tuples[k][1]])
    int* outDegrees = new int[ntwk.nodeCnt];        // outDegrees[nodeID] = out-degree of corresponding node

    for (int dstID=0; dstID<=ntwk.nodeCnt; dstID++) {
        int numDependencies = ntwk.offsets[dstID+1]-ntwk.offsets[dstID];
        for (int i=0; i<numDependencies; i++) {
            int srcID = ntwk.csr[ntwk.offsets[dstID]+i];
            tuples[tupleCnt][0] = srcID;
            tuples[tupleCnt][1] = dstID;
            outDegrees[srcID]++;
            tupleCnt++;
        }
    }

    // Sort tuples by srcID, in ascending order
    qsort((void*)tuples, ntwk.edgeCnt, sizeof(int*), comparator);

    // Configure offsets for outgoing-csr
    out_offs[0] = 0;
    int appendCntr = 0;
    for (int source=0; source<ntwk.nodeCnt; source++) {
        out_offs[source+1] = out_offs[source] + outDegrees[source];
        for (int i=0; i<outDegrees[source]; i++) {
            out_csr[out_offs[source]+i] = tuples[appendCntr][1];
            appendCntr++;
        }
    }

    free(outDegrees);
}

// Columnizes a network. Assumes that all fields are set except for colIdxs and colIDs
int columnize(Network ntwk) {
    int colCounter = 0;
    int nCnt = ntwk.nodeCnt;
    int sCnt = ntwk.sourceCnt;
    int curSourcesLength = sCnt;
    int* inDegrees = new int[nCnt];
    int* curSources = new int[nCnt];
    int* frontier = new int[nCnt];
    int* frwrd_offsets = new int[ntwk.nodeCnt+1];
    int* frwrd_csr = new int[ntwk.edgeCnt];

    // Generate forward-edge (outgoing) graph representation
    gen_outgoing_csr(ntwk, frwrd_offsets, frwrd_csr);

    // Populate inDegrees
    for (int k=0; k<nCnt; k++) {
        inDegrees[k] = ntwk.offsets[k+1]-ntwk.offsets[k];
    }

    // Populate curSources with source IDs to begin with
    memcpy(curSources, ntwk.sourceIDs, sCnt*sizeof(int));
    int curColIDsLength = 0;

    // Loop until all nodes have been placed into a column
    while (curSourcesLength != 0) {
        // Initialize next entry in colIdxs to continue the prefix sum
        ntwk.colIdxs[colCounter+1] = ntwk.colIdxs[colCounter];
        int frontierLength = 0;

        for (int i=0; i<curSourcesLength; i++) {
            // Flush each curSource to a column and decrement its inDegree so it isn't picked up again
            int nodeID = curSources[i];
            ntwk.colIDs[curColIDsLength] = nodeID;
            curColIDsLength++;
            inDegrees[nodeID]--;

            // Bump the current column's offset
            ntwk.colIdxs[colCounter+1]++;

            // Decrement inDegree count for each node outgoing from a curSource
            int outDeg = frwrd_offsets[nodeID+1]-frwrd_offsets[nodeID];
            for (int k=0; k<outDeg; k++) {
                inDegrees[frwrd_csr[frwrd_offsets[nodeID]+k]]--;
            }
        }

        // Append all nodes that have exactly 0 inDegree to the frontier
        for (int j=0; j<nCnt; j++) {
            if (inDegrees[j] == 0) {
                frontier[frontierLength] = j;
                frontierLength++;
            }
        }

        // Flush frontier to curSources
        // I think this can all be optimized by actually dual-buffering here. Too much memcpy...
        memset(curSources, 0, nCnt*sizeof(int));
        memcpy(curSources, frontier, frontierLength*sizeof(int));
        memset(frontier, 0, nCnt*sizeof(int));
        curSourcesLength = frontierLength;
        colCounter++;
    }
    free(inDegrees);
    free(curSources);
    free(frontier);
    free(frwrd_offsets);
    free(frwrd_csr);
    return colCounter;
}




__global__ void srcKernel(Network ntwk, int cycleID) {
    // Get the ID of the i-th source node
    int i = threadIdx.x;
    int nodeID = ntwk.sourceIDs[i];

    // Set output as the source bit from the right cycle-set
    ntwk.outputBits[cycleID*ntwk.nodeCnt + nodeID] = ntwk.sourceBits[cycleID*ntwk.sourceCnt + i];
}

__global__ void genKernel(Network ntwk, int colNum, int cycleID) {
    // Get the ID of the i-th node in the column
    int i = threadIdx.x;
    int nodeID = ntwk.colIDs[ntwk.colIdxs[colNum] + i];
    int cycleSet = cycleID*ntwk.nodeCnt;

    // Get the IDs of its previous nodes by looking up in offsets and csr
    int prvNdStartIdx = ntwk.offsets[nodeID];
    int width = ntwk.offsets[nodeID+1]-ntwk.offsets[nodeID];                            //<TODO> if this quantity is 1 then is object for sure
                                                                                        //a register? If so can do away with regIndicator.
    int lookupIdx = 0;

    // Get the outputs from the previous nodes (these are the inputs to the i-th node)
    for (int j=0; j<width; j++) {
        int prvNdID = ntwk.csr[j + prvNdStartIdx];
        int prvOutput = ntwk.outputBits[cycleSet + prvNdID];
        if (prvOutput) {
            lookupIdx |= (1 << width-1-j);
        }
    }

    if (ntwk.regIndicator[nodeID]) {
        // Node is a register, send old-gen-val to outputBits and new-gen-val to regBuffer
        int regID = ntwk.typeIDs[nodeID];
        ntwk.outputBits[cycleSet + nodeID] = ntwk.regBuffer[regID];
        ntwk.regBuffer[regID] = lookupIdx;
    } else {
        // Node is a LUT, find the correct lutBit to bitmask with lookupIdx
        int lutID = ntwk.typeIDs[nodeID];
        int intSizeInBits = 8*sizeof(int);
        int quotient = lookupIdx / intSizeInBits;
        int residue = lookupIdx % intSizeInBits;
        int mask = 1 << residue;
        int sectionIdx = ntwk.lutOffsets[lutID] + quotient;
        int sectionBits = ntwk.lutBits[sectionIdx];

        // Get LUT output by bitmasking the residue of lookupIdx against the section from lutBits
        if (mask & sectionBits) {
            ntwk.outputBits[cycleSet + nodeID] = 1;
        } else {
            ntwk.outputBits[cycleSet + nodeID] = 0;
        }
    }
}

















int reader(int* ndCnt, int* edgCnt, int* lutCnt, int* regCnt, int*srcCnt,
        std::vector<int>& regInd_vec,
        std::vector<int>& typeIDs_vec,
        std::vector<int>& srcIDs_vec,
        std::vector<int>& offs_vec,
        std::vector<int>& csr_vec,
        std::vector<int>& lutOffs_vec,
        std::vector<unsigned int>& lutBts_vec) {

    // Define max lengths and container for lines
    int maxLineChars = 1000;
    int maxDigits = 6;
    char line[maxLineChars];

    // Open target file
    FILE *file = fopen("graph.txt", "r");
    if (file == NULL) {
        fprintf(stderr, "Error opening graph.txt\n");
        return 1;
    }

    // Read line 0 for nodecount
    if (fgets(line, maxLineChars, file) != NULL) {
        *ndCnt = atoi(line);
    } else {
        fprintf(stderr, "Error parsing nodecount from line: %s\n", line);
        return 1;
    }

    // Clear line
    memset(line, 0, maxLineChars*sizeof(char));

    // Initialize certain arrays
    std::vector<int> indctr(*ndCnt, 0);
    std::vector<int> typIDs(*ndCnt, 0);
    lutOffs_vec.push_back(0);
    offs_vec.push_back(0);

    // Read file line by line
    int lnCntr = 0;
    int ltOffsCntr = 0;
    int offsCntr = 0;
    while (fgets(line, maxLineChars, file) != NULL) {
        lnCntr++;
        char nodeID[maxDigits], lutWidth[maxDigits], lutInfo[maxLineChars], regDependencies[maxLineChars];
        if (sscanf(line, "%s INPUT %s", nodeID, nodeID) == 2) {                         // Process INPUT
            int id = atoi(nodeID);
            srcIDs_vec.push_back(id);
            typIDs[id] = *srcCnt;
            offs_vec.push_back(offsCntr);
            (*srcCnt)++;
        } else if (sscanf(line, "%s REG %s", nodeID, regDependencies) == 2) {           // Process REG
            int id = atoi(nodeID);
            indctr[id] = 1;
            typIDs[id] = *regCnt;
            offsCntr++;
            offs_vec.push_back(offsCntr);
            std::string dep(regDependencies);
            int depID = std::stoi(dep.substr(1, dep.length()-1));
            csr_vec.push_back(depID);

            (*edgCnt)++;
            (*regCnt)++;
        } else if (sscanf(line, "%s LUT %s %[^\n]", nodeID, lutWidth, lutInfo) == 3) {  // Process LUT
            int id = atoi(nodeID);
            int width = atoi(lutWidth);
            int intSize = 8*sizeof(int);
            int numIntsNeeded = 1;
            if (width > intSize) {
                numIntsNeeded = width / intSize;
                if (width % intSize != 0) {
                    numIntsNeeded++;
                }
            }
            // update lutOffs
            ltOffsCntr += numIntsNeeded;
            lutOffs_vec.push_back(ltOffsCntr);

            // retrieve lut bits and dependencies
            unsigned int curSum = 0;
            int bitCounter = 0;

            // consolidate all lut bits into one number
            int numFlushed = 0;
            for (int j=0; j<width; j++) {
                char curBit;
                curBit = lutInfo[2*j];
                curSum += (atoi(&curBit) << (width-j-1));
                bitCounter++;
                if (bitCounter >= 32) {
                    // flush current int to lutBits and reset curSum and bitCounter
                    lutBts_vec.push_back(curSum);
                    bitCounter = 0;
                    curSum = 0;
                    numFlushed++;
                }
            }

            // flush curSum to lutBits if within numIntsNeeded
            if (numFlushed < numIntsNeeded) {
                lutBts_vec.push_back(curSum);
            }

            // handle dependencies
            std::string info(lutInfo);
            std::string deps = info.substr(2*width, info.length()-1);
            std::string dep;
            std::stringstream strStrm(deps);
            while (std::getline(strStrm, dep, ' ')) {
                // test for validity of dependency
                if (dep.find('D' != std::string::npos)) {
                    // increment edge and offset counts
                    (*edgCnt)++;
                    offsCntr++;
                    std::string depID = dep.substr(1, dep.length()-1);
                    // append to csr
                    csr_vec.push_back(std::stoi(depID));
                }
            }

            // update offsets vector
            offs_vec.push_back(offsCntr);

            typIDs[id] = *lutCnt;
            (*lutCnt)++;
        } else {
            fprintf(stderr, "Error parsing line: %s\n", line);
        }
    }
    regInd_vec = indctr;
    typeIDs_vec = typIDs;
    fclose(file);
    return 0;
}











/*
SPECIFIED BY USER INPUT WAVEFORM (TODO):
    cycleCnt
    srcBts

HANDLED BY COLUMNIZATION:
    colIdxs
    colIDs

LEFT UNSPECIFIED (no action needed):
    regBuf
    outBts
*/




int main() {
    // Int containers to be populated in reader function
    int* numNodes = new int(0);
    int* numEdges = new int(0);
    int* numLuts = new int(0);
    int* numRegs = new int(0);
    int* numSrcs = new int(0);

    // Vectors to be populated in reader function
    std::vector<int> srcIDs_vec;
    std::vector<int> offs_vec;
    std::vector<int> csr_vec;
    std::vector<int> lutOffs_vec;
    std::vector<unsigned int> lutBts_vec;
    std::vector<int> regInd_vec;
    std::vector<int> typeIDs_vec;

    // Call reader function; this fills all num<field> vars and populates vectors
    if (reader(numNodes, numEdges, numLuts, numRegs, numSrcs,
                regInd_vec, typeIDs_vec, srcIDs_vec, offs_vec, csr_vec, lutOffs_vec, lutBts_vec)) {
        return 1;
    }

    // These fields are passed by value to the device
    int cycleCnt = 5;           //<TODO> automate the initialization
                                //of this variable when the user
                                //specifies their input waveform
    int colCnt = 0;
    int ndCnt = *numNodes;
    int edgCnt = *numEdges;
    int lutCnt = *numLuts;
    int regCnt = *numRegs;
    int srcCnt = *numSrcs;

    // These fields are sent to the device and copied as pointers
    // Note that these are host-accessible only
    //<TODO><TODO><TODO><TODO> set all as new int[size] and then later memcpy(vec.data()->arr);
    int* host_srcIDs = new int[srcCnt];
    int* host_srcBts = new int[srcCnt*cycleCnt];
    int* host_offs = new int[1+ndCnt];
    int* host_csr = new int[edgCnt];
    int* host_typeIDs = new int[ndCnt];
    int* host_regInd = new int[ndCnt];
    int* host_regBuf = new int[regCnt];
    int* host_lutOffs = new int[1+lutCnt];
    unsigned int* host_lutBts = new unsigned int[lutCnt];
    int* host_outBts = new int[ndCnt*cycleCnt];
    int* host_colIdxs = new int[1+ndCnt];
    int* host_colIDs =  new int[ndCnt];

    /*    host_srcIDs = new int[srcCnt]{0,1,2,3};
    host_srcBts = new int[srcCnt*cycleCnt]{0,0,0,0, 1,0,0,0, 1,0,0,0, 1,1,1,1, 0,1,1,0};
    host_offs = new int[ndCnt+1]{0,0,0,0,0,2,4,5,7};
    host_csr = new int[edgCnt]{0,1,2,3,4,6,5};
    host_typeIDs = new int[ndCnt]{0,1,2,3,0,1,0,2};
    host_regInd = new int[ndCnt]{0,0,0,0,0,0,1,0};
    host_regBuf = new int[regCnt];
    host_lutOffs = new int[lutCnt+1]{0,1,2,3};
    host_lutBts = new unsigned int[lutCnt]{4,14,1};
    host_outBts = new int[ndCnt*cycleCnt];
    host_colIdxs = new int[ndCnt+1];                                        //<CAREFUL> we're allocating this for ndCnt+1 because we really want colCnt+1
    host_colIDs = new int[ndCnt];                                           // but we calculate colCnt only once we columnize and populate these fields.
    */

    // Transfer vector info to arrays
    memcpy(host_srcIDs, srcIDs_vec.data(), sizeof(int)*srcCnt);
    memcpy(host_offs, offs_vec.data(), sizeof(int)*(1+ndCnt));
    memcpy(host_csr, csr_vec.data(), sizeof(int)*edgCnt);
    memcpy(host_lutOffs, lutOffs_vec.data(), sizeof(int)*(1+lutCnt));
    memcpy(host_lutBts, lutBts_vec.data(), sizeof(int)*lutCnt);
    memcpy(host_regInd, regInd_vec.data(), sizeof(int)*ndCnt);
    memcpy(host_typeIDs, typeIDs_vec.data(), sizeof(int)*ndCnt);
    /*host_srcIDs = srcIDs_vec.data();
    host_offs = offs_vec.data();
    host_csr = csr_vec.data();
    host_lutOffs = lutOffs_vec.data();
    host_lutBts = lutBts_vec.data();
    host_regInd = regInd_vec.data();
    host_typeIDs = typeIDs_vec.data();*/

    // Transfer int containers
    ndCnt = *numNodes;
    edgCnt = *numEdges;
    lutCnt = *numLuts;
    regCnt = *numRegs;
    srcCnt = *numSrcs;

    // Free containers
    free(numNodes);
    free(numEdges);
    free(numLuts);
    free(numRegs);
    free(numSrcs);

    // Initialize input waveform parameters (TODO - automate this)
    cycleCnt = 5;

    /*host_srcBts = new int[srcCnt*cycleCnt];
    // init input bits to all zeroes (TODO - automate this)
    std::fill(host_srcBts, host_srcBts+(srcCnt*cycleCnt), 0);*/
    host_srcBts = new int[srcCnt*cycleCnt]{0,0,0,0, 1,0,0,0, 1,0,0,0, 1,1,1,1, 0,1,1,0};

    host_outBts = new int[ndCnt*cycleCnt];
    host_colIdxs = new int[ndCnt+1];
    host_colIDs = new int[ndCnt];

    // One chief_net to rule them all, one chief_net to find them.
    Network chief_net = Network(srcCnt, host_srcIDs, host_srcBts,
            ndCnt, edgCnt, colCnt, lutCnt, regCnt, host_offs, host_csr,
            host_typeIDs, host_regInd, host_regBuf, host_lutOffs,
            host_lutBts, host_outBts, host_colIdxs, host_colIDs);

    // Columnize and set the number of columns
    chief_net.colCnt = columnize(chief_net);
    colCnt = chief_net.colCnt;

    // These fields exist on the device
    int* dev_srcIDs;
    int* dev_srcBts;
    int* dev_offs;
    int* dev_csr;
    int* dev_typeIDs;
    int* dev_regInd;
    int* dev_regBuf;
    int* dev_lutOffs;
    unsigned int* dev_lutBts;
    int* dev_outBts;
    int* dev_colIdxs;
    int* dev_colIDs;

    // Allocate space for all pointers we're copying
    cudaMalloc((void**) &(dev_srcIDs), sizeof(int)*srcCnt);
    cudaMalloc((void**) &(dev_srcBts), sizeof(int)*srcCnt*cycleCnt);
    cudaMalloc((void**) &(dev_offs), sizeof(int)*(ndCnt+1));
    cudaMalloc((void**) &(dev_csr), sizeof(int)*edgCnt);
    cudaMalloc((void**) &(dev_typeIDs), sizeof(int)*ndCnt);
    cudaMalloc((void**) &(dev_regInd), sizeof(int)*ndCnt);
    cudaMalloc((void**) &(dev_regBuf), sizeof(int)*regCnt);
    cudaMalloc((void**) &(dev_lutOffs), sizeof(int)*(lutCnt+1));
    cudaMalloc((void**) &(dev_lutBts), sizeof(int)*lutCnt);
    cudaMalloc((void**) &(dev_outBts), sizeof(int)*ndCnt*cycleCnt);
    cudaMalloc((void**) &(dev_colIdxs), sizeof(int)*(colCnt+1));
    cudaMalloc((void**) &(dev_colIDs), sizeof(int)*ndCnt);

    // Copy contents from host to device
    cudaMemcpy(dev_srcIDs, host_srcIDs, sizeof(int)*srcCnt, cudaMemcpyHostToDevice);
    cudaMemcpy(dev_srcBts, host_srcBts, sizeof(int)*srcCnt*cycleCnt, cudaMemcpyHostToDevice);
    cudaMemcpy(dev_offs, host_offs, sizeof(int)*(ndCnt+1), cudaMemcpyHostToDevice);
    cudaMemcpy(dev_csr, host_csr, sizeof(int)*edgCnt, cudaMemcpyHostToDevice);
    cudaMemcpy(dev_typeIDs, host_typeIDs, sizeof(int)*ndCnt, cudaMemcpyHostToDevice);
    cudaMemcpy(dev_regInd, host_regInd, sizeof(int)*ndCnt, cudaMemcpyHostToDevice);
    cudaMemcpy(dev_regBuf, host_regBuf, sizeof(int)*regCnt, cudaMemcpyHostToDevice);
    cudaMemcpy(dev_lutOffs, host_lutOffs, sizeof(int)*(lutCnt+1), cudaMemcpyHostToDevice);
    cudaMemcpy(dev_lutBts, host_lutBts, sizeof(int)*lutCnt, cudaMemcpyHostToDevice);
    cudaMemcpy(dev_outBts, host_outBts, sizeof(int)*ndCnt*cycleCnt, cudaMemcpyHostToDevice);
    cudaMemcpy(dev_colIdxs, host_colIdxs, sizeof(int)*(colCnt+1), cudaMemcpyHostToDevice);
    cudaMemcpy(dev_colIDs, host_colIDs, sizeof(int)*ndCnt, cudaMemcpyHostToDevice);

    // Point to device pointers from chief_net
    chief_net.sourceIDs = dev_srcIDs;
    chief_net.sourceBits = dev_srcBts;
    chief_net.offsets = dev_offs;
    chief_net.csr = dev_csr;
    chief_net.typeIDs = dev_typeIDs;
    chief_net.regIndicator = dev_regInd;
    chief_net.regBuffer = dev_regBuf;
    chief_net.lutOffsets = dev_lutOffs;
    chief_net.lutBits = dev_lutBts;
    chief_net.outputBits = dev_outBts;
    chief_net.colIdxs = dev_colIdxs;
    chief_net.colIDs = dev_colIDs;

    // Run cycle simulation on the kernels                          <TODO> possible optimization: try merging the kernels and calling one kernel on colCnt many synchronized blocks
                                                                        // instead, since this will minimize CPU-GPU communication latency and make the bulk of the simulation internal on the GPU.
    for (int k=0; k<cycleCnt; k++) {
        printf("\n<<<<<<<<<entering cycle [%d]>>>>>>>>", k);
        // Invoke srcKernel once using srcCnt many threads
        srcKernel<<<1, srcCnt>>>(chief_net, k);
        cudaDeviceSynchronize();

        // Invoke genKernel once per non-source column (in-order), using as many threads as there are nodes in the column
        for (int i=1; i<colCnt; i++) {
            int columnHeight = host_colIdxs[i+1]-host_colIdxs[i];
            genKernel<<<1, columnHeight>>>(chief_net, i, k);
            cudaDeviceSynchronize();
        }
    }

    // Copy results from device to host
    cudaMemcpy(host_outBts, dev_outBts, sizeof(int)*ndCnt*cycleCnt, cudaMemcpyDeviceToHost);

    // Print simulation outputs
    printf("\n");
    for (int k=0; k<cycleCnt; k++) {
        printf(" _______________________________\n");
        printf("|        CYCLE[%d] RESULTS       |\n", k);
        printf("|-------------------------------|\n");
        for (int j=0; j<ndCnt; j++) {
            printf("|    Node[%d]'s output is [%d]    |\n", j, host_outBts[k*ndCnt + j]);
        }
        printf("|_______________________________|\n");
    }

    // Free device pointers
    cudaFree(dev_srcIDs);
    cudaFree(dev_srcBts);
    cudaFree(dev_offs);
    cudaFree(dev_csr);
    cudaFree(dev_typeIDs);
    cudaFree(dev_regInd);
    cudaFree(dev_regBuf);
    cudaFree(dev_lutOffs);
    cudaFree(dev_lutBts);
    cudaFree(dev_outBts);
    cudaFree(dev_colIdxs);
    cudaFree(dev_colIDs);

    // Free host pointers
    free(host_srcIDs);
    free(host_srcBts);
    free(host_offs);
    free(host_csr);
    free(host_typeIDs);
    free(host_regInd);
    free(host_regBuf);
    free(host_lutOffs);
    free(host_lutBts);
    free(host_outBts);
    free(host_colIdxs);
    free(host_colIDs);

    return 0;
}








