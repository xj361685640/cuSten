// Andrew Gloster
// May 2018
// Kernel to apply an x direction stencil on a 2D grid - non periodic

//   Copyright 2018 Andrew Gloster

//   Licensed under the Apache License, Version 2.0 (the "License");
//   you may not use this file except in compliance with the License.
//   You may obtain a copy of the License at

//       http://www.apache.org/licenses/LICENSE-2.0

//   Unless required by applicable law or agreed to in writing, software
//   distributed under the License is distributed on an "AS IS" BASIS,
//   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//   See the License for the specific language governing permissions and
//   limitations under the License.

// ---------------------------------------------------------------------
//  Standard Libraries and Headers
// ---------------------------------------------------------------------

#include <iostream>
#include <cstdio>

// ---------------------------------------------------------------------
// Custom libraries and headers
// ---------------------------------------------------------------------

#include "../util/util.h"
#include "../struct/cuSten_struct_type.h"

// ---------------------------------------------------------------------
// Function pointer definition
// ---------------------------------------------------------------------

// Data -- Coefficients -- Current node index
typedef double (*devArg1X)(double*, double*, int);

// ---------------------------------------------------------------------
//  Kernel Definition
// ---------------------------------------------------------------------

__global__ void kernel2DXpFun
(
	double* dataNew,  					// Answer data

	double* dataOld,					// Input data

	const double* coe,						// User defined coefficients		

	const double* func,						// The user input function

	const int numStenLeft,				// Number of points to the left
	const int numStenRight,				// Number of points to the right

	const int numCoe,					// Number of user defined coefficients

	const int nxLocal,					// Number of points in shared memory in x direction
	const int nyLocal,					// Number of points in shared memory in y direction

	const int BLOCK_X,					// Number of threads in block in y

	const int nx						// Total number of points in x
)
{	
	// Allocate the shared memory
	extern __shared__ int memory[];

	double* arrayLocal = (double*)&memory;
	double* coeLocal = (double*)&arrayLocal[nxLocal * nyLocal];

	// Move the weigths into shared memory
	#pragma unroll
	for (int k = 0; k < numCoe; k++)
	{
		coeLocal[k] = coe[k];
	}

	// True matrix index
    int globalIdx = blockDim.x * blockIdx.x + threadIdx.x;
	int globalIdy = blockDim.y * blockIdx.y + threadIdx.y;

	// Local matrix index
	int localIdx = threadIdx.x + numStenLeft;
	int localIdy = threadIdx.y;

	// Set index for summing stencil
	int stenSet;

	// Set all interior blocks
	if (blockIdx.x != 0 && blockIdx.x != nx / (BLOCK_X) - 1)
	{
		arrayLocal[localIdy * nxLocal + localIdx] = dataOld[globalIdy * nx + globalIdx];

		if (threadIdx.x < numStenLeft)
		{
			arrayLocal[localIdy * nxLocal + threadIdx.x] = dataOld[globalIdy * nx + (globalIdx - numStenLeft)];
		}

		if (threadIdx.x < numStenRight)
		{
			arrayLocal[localIdy * nxLocal + (localIdx + BLOCK_X)] = dataOld[globalIdy * nx + globalIdx + BLOCK_X];
		}
	}

	// Set all left boundary blocks
	if (blockIdx.x == 0)
	{
		arrayLocal[localIdy * nxLocal + localIdx] = dataOld[globalIdy * nx + globalIdx];

		if (threadIdx.x < numStenLeft)
		{
			arrayLocal[localIdy * nxLocal + threadIdx.x] = dataOld[globalIdy * nx + (nx - numStenLeft + threadIdx.x)];
		}

		if (threadIdx.x < numStenRight)
		{
			arrayLocal[localIdy * nxLocal + (localIdx + BLOCK_X)] = dataOld[globalIdy * nx + globalIdx + BLOCK_X];
		}
	}

	// Set the right boundary blocks
	if (blockIdx.x == nx / BLOCK_X - 1)
	{
		arrayLocal[localIdy * nxLocal + threadIdx.x + numStenLeft] = dataOld[globalIdy * nx + globalIdx];

		if (threadIdx.x < numStenLeft)
		{
			arrayLocal[localIdy * nxLocal + threadIdx.x] = dataOld[globalIdy * nx + (globalIdx - numStenLeft)];
		}

		if (threadIdx.x < numStenRight)
		{
			arrayLocal[localIdy * nxLocal + (localIdx + BLOCK_X)] = dataOld[globalIdy * nx + threadIdx.x];
		}
	}

	__syncthreads();

	stenSet = localIdy * nxLocal + localIdx;

	dataNew[globalIdy * nx + globalIdx] = ((devArg1X)func)(arrayLocal, coeLocal, stenSet);
}

// ---------------------------------------------------------------------
// Function to compute kernel
// ---------------------------------------------------------------------

void custenCompute2DXpFun
(
	cuSten_t* pt_cuSten,

	bool offload
)
{	
	// Buffer used for error checking
	char msgStringBuffer[1024];

	// Set current active compute device
	cudaSetDevice(pt_cuSten->deviceNum);
	sprintf(msgStringBuffer, "Setting current device to GPU %d", pt_cuSten->deviceNum);
	checkError(msgStringBuffer);

	dim3 blockDim(pt_cuSten->BLOCK_X, pt_cuSten->BLOCK_Y);
	dim3 gridDim(pt_cuSten->xGrid, pt_cuSten->yGrid);

	// Preload the first block
	cudaStreamSynchronize(pt_cuSten->streams[1]);
	cudaMemPrefetchAsync(pt_cuSten->dataInput[0], pt_cuSten->nxDevice * pt_cuSten->nyTile * sizeof(double), pt_cuSten->deviceNum, pt_cuSten->streams[1]);
	cudaMemPrefetchAsync(pt_cuSten->dataOutput[0], pt_cuSten->nxDevice * pt_cuSten->nyTile * sizeof(double), pt_cuSten->deviceNum, pt_cuSten->streams[1]);
	cudaEventRecord(pt_cuSten->events[1], pt_cuSten->streams[1]);

	// Temporary stream and event used for permuting
	cudaStream_t ts;
	cudaEvent_t te;

	// Loop over the tiles
	for (int tile = 0; tile < pt_cuSten->numTiles; tile++)
	{
		// Synchronise the events to ensure computation overlaps
		cudaEventSynchronize(pt_cuSten->events[0]);
		cudaEventSynchronize(pt_cuSten->events[1]);

		// Preform the computation on the current tile
		kernel2DXpFun<<<gridDim, blockDim, pt_cuSten->mem_shared, pt_cuSten->streams[0]>>>(
			pt_cuSten->dataOutput[tile], 
			pt_cuSten->dataInput[tile], 
			pt_cuSten->coe, 
			pt_cuSten->devFunc, 
			pt_cuSten->numStenLeft,
			pt_cuSten->numStenRight, 
			pt_cuSten->numCoe, 
			pt_cuSten->nxLocal, 
			pt_cuSten->nyLocal, 
			pt_cuSten->BLOCK_X, 
			pt_cuSten->nxDevice
		);

		cudaEventRecord(pt_cuSten->events[0], pt_cuSten->streams[0]);

		// Offload should the user want to
		if (offload == 1)
		{
			cudaMemPrefetchAsync(pt_cuSten->dataOutput[tile], pt_cuSten->nxDevice * pt_cuSten->nyTile * sizeof(double), cudaCpuDeviceId, pt_cuSten->streams[0]);
	    	cudaMemPrefetchAsync(pt_cuSten->dataInput[tile], pt_cuSten->nxDevice * pt_cuSten->nyTile * sizeof(double), cudaCpuDeviceId, pt_cuSten->streams[0]);
		}

		// Load the next tile
    	if (tile < pt_cuSten->numTiles - 1)
    	{
    		cudaStreamSynchronize(pt_cuSten->streams[1]);
			cudaMemPrefetchAsync(pt_cuSten->dataOutput[tile + 1], pt_cuSten->nxDevice * pt_cuSten->nyTile * sizeof(double), pt_cuSten->deviceNum, pt_cuSten->streams[1]);
		 	cudaMemPrefetchAsync(pt_cuSten->dataInput[tile + 1], pt_cuSten->nxDevice * pt_cuSten->nyTile * sizeof(double), pt_cuSten->deviceNum, pt_cuSten->streams[1]);
			cudaEventRecord(pt_cuSten->events[1], pt_cuSten->streams[1]);
    	}

    	// Permute streams
    	for (int i = 0; i < pt_cuSten->numStreams - 1; i++)
    	{
    		ts = pt_cuSten->streams[i];
    		pt_cuSten->streams[i] = pt_cuSten->streams[i + 1];	
    		pt_cuSten->streams[i + 1] = ts;    			
    	}

    	// Permute events
		te = pt_cuSten->events[0]; pt_cuSten->events[0] = pt_cuSten->events[1]; pt_cuSten->events[1] = te; 
    }
}

// ---------------------------------------------------------------------
// End of file
// ---------------------------------------------------------------------