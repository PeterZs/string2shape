#ifdef _MSC_VER
#pragma once
#endif

#ifndef WIGGLE_H_D31D930E_4861_4383_901F_3FC7AA0D14AC
#define WIGGLE_H_D31D930E_4861_4383_901F_3FC7AA0D14AC

#include "Algebra.h"
#include "WFObject.h"
#include "Graph.h"

#include <thrust/host_vector.h>

class Wiggle
{
	thrust::host_vector<unsigned int> mIntervals;
	//Node a's type
	thrust::host_vector<unsigned int> mNeighborTypeKeys;
	//Node b's type
	thrust::host_vector<unsigned int> mNeighborTypeVals;
	//Center of gravity of b in a's coordinate system
	thrust::host_vector<float3> mRelativeTranslation;
	//Rotates a's local coordinate frame into b's
	thrust::host_vector<quaternion4f> mRelativeRotation;
	//Rotates the canonical coordinates into b's
	thrust::host_vector<quaternion4f> mAbsoluteRotation;

public:
	float spatialTolerance;
	float angleTolerance;

	Wiggle():spatialTolerance(-0.001f), angleTolerance(0.0038053019f)//1.f - cos(5)
	{}

	__host__ void init(
		WFObject& aObj,
		Graph & aGraph);

	__host__ void fixRelativeTransformations(
		WFObject& aObj,
		Graph & aGraph);

	__host__ void processNeighbors(
		WFObject&							aObj,
		unsigned int						aNodeId,
		thrust::host_vector<unsigned int>&	visited,
		thrust::host_vector<unsigned int>&	intervalsHost,
		thrust::host_vector<unsigned int>&	adjacencyValsHost,
		thrust::host_vector<unsigned int>&	nodeTypeIds);

	__host__ void findBestMatch(
		unsigned int		aTypeId1,
		unsigned int		aTypeId2,
		const float3&		aTranslation,
		const quaternion4f&	aRotation,
		float3&				oTranslation,
		quaternion4f&		oRotation);

	//transforms object's position and orientation B->A->C
	__host__ void transformObj(
		WFObject& aObj,
		unsigned int aObjId,
		const float3& aTranslation0toB,
		const quaternion4f& aRotationBtoAtoC
		);
};


#endif // WIGGLE_H_D31D930E_4861_4383_901F_3FC7AA0D14AC
