#include "pch.h"
#include "Wiggle.h"

#include <deque>

#include "WFObjUtils.h"
#include "SVD.h"

#include "DebugUtils.h"

#include <thrust/device_vector.h>
#include <thrust/host_vector.h>
#include <thrust/copy.h>
#include <thrust/sort.h>

class LocalCoordsEstimator
{
	static const bool USE_PCA = false;
public:
	uint2*			vertexRanges;
	float3*			vertexBuffer;
	double*			tmpCovMatrix;
	double*			tmpDiagonalW;
	double*			tmpMatrixV;
	double*			tmpVecRV;
	float3*			outTranslation;
	quaternion4f*	outRotation;


	LocalCoordsEstimator(
		uint2*			aRanges,
		float3*			aBuffer,
		double*			aCovMatrix,
		double*			aDiagonalW,
		double*			aMatrixV,
		double*			aVecRV,
		float3*			aOutTranslation,
		quaternion4f*	aOutRot
	) : 
		vertexRanges(aRanges),
		vertexBuffer(aBuffer),
		tmpCovMatrix(aCovMatrix),
		tmpDiagonalW(aDiagonalW),
		tmpMatrixV(aMatrixV),
		tmpVecRV(aVecRV),
		outTranslation(aOutTranslation),
		outRotation(aOutRot)
	{}

	__host__ __device__	void operator()(const size_t& aId)
	{
		const unsigned int objId = (unsigned)aId;


		//Compute the mean of the vertex locations
		float3 center = make_float3(0.f, 0.f, 0.f);
		uint2 vtxRange = vertexRanges[objId];
		unsigned int vtxCount = vtxRange.y - vtxRange.x;
		float numPoints = (float)vtxCount;

		for (unsigned int vtxId = 0; vtxId < vtxCount; ++vtxId)
		{
			center += vertexBuffer[vtxRange.x + vtxId];
		}
		center /= numPoints;

		outTranslation[aId] = center;

		//Find the vertex furthest away from the center
		float3 vtx0 = center;
		float dist0 = 0.f;
		for (unsigned int vtxId = 0; vtxId < vtxCount; ++vtxId)
		{
			const float3 vec = vertexBuffer[vtxRange.x + vtxId];
			const float3 delta = vec - center;
			const float distSQR = dot(delta, delta);
			if (distSQR > dist0)
			{
				vtx0 = vec;
				dist0 = distSQR;
			}
		}
		//Find the other end of the diameter
		float3 vtx1 = vtx0;
		float diameter = 0.f;
		for (unsigned int vtxId = 0; vtxId < vtxCount; ++vtxId)
		{
			const float3 vec = vertexBuffer[vtxRange.x + vtxId];
			const float3 delta = vec - vtx0;
			const float distSQR = dot(delta, delta);
			if (distSQR > diameter)
			{
				vtx1 = vec;
				diameter = distSQR;
			}
		}
		const float3 dir0 = ~(vtx1 - vtx0);
		//Find the vertex furthest away from the diameter
		float3 vtx2 = vtx0;
		float dist2 = 0.f;
		float distC = 0.f;
		for (unsigned int vtxId = 0; vtxId < vtxCount; ++vtxId)
		{
			const float3 vec = vertexBuffer[vtxRange.x + vtxId];
			const float3 delta = cross(dir0, vec - vtx0);
			const float distSQR = dot(delta, delta);
			const float distCenterSQR = dot(vec - center, vec - center);
			if (distSQR >= dist2
				//if multiple points have the max distance to the diameter, choose the one furtherst away from the center
				|| (dist2 - distSQR < 0.001f * dist2 && distCenterSQR > distC && distCenterSQR - distC > 0.01f * distC)
				)
			{
				vtx2 = vec;
				dist2 = distSQR;
				distC = distCenterSQR;
			}
		}
		const float3 dir1 = ~((vtx2 - vtx0) - dir0 * dot(vtx2 - vtx0, dir0));
		const float3 dir2 = ~cross(dir0, dir1);

		quaternion4f rotation(
			dir0.x, dir1.x, dir2.x,
			dir0.y, dir1.y, dir2.y,
			dir0.z, dir1.z, dir2.z
		);

		outRotation[aId] = rotation;

		if (USE_PCA)
		{
			//Compute covariance matrix
			double* covMat = thrust::raw_pointer_cast(tmpCovMatrix + aId * 3 * 3);
			for (unsigned int vtxId = 0; vtxId < vtxCount; ++vtxId)
			{
				float3 vec1 = vertexBuffer[vtxRange.x + vtxId] - center;

				covMat[0 * 3 + 0] += (double)vec1.x * vec1.x;
				covMat[1 * 3 + 0] += (double)vec1.y * vec1.x;
				covMat[2 * 3 + 0] += (double)vec1.z * vec1.x;

				covMat[0 * 3 + 1] += (double)vec1.x * vec1.y;
				covMat[1 * 3 + 1] += (double)vec1.y * vec1.y;
				covMat[2 * 3 + 1] += (double)vec1.z * vec1.y;

				covMat[0 * 3 + 2] += (double)vec1.x * vec1.z;
				covMat[1 * 3 + 2] += (double)vec1.y * vec1.z;
				covMat[2 * 3 + 2] += (double)vec1.z * vec1.z;
			}

			//Singular Value Decomposition
			double* diag = thrust::raw_pointer_cast(tmpDiagonalW + aId * 3);
			double* vMat = thrust::raw_pointer_cast(tmpMatrixV + aId * 3 * 3);
			double* tmp = thrust::raw_pointer_cast(tmpVecRV + aId * 3);

			svd::svdcmp(covMat, 3, 3, diag, vMat, tmp);

			const float3 col0 = make_float3((float)vMat[0], (float)vMat[1], (float)vMat[2]);
			const float3 col1 = make_float3((float)vMat[3], (float)vMat[4], (float)vMat[5]);
			const float3 col2 = make_float3((float)vMat[6], (float)vMat[7], (float)vMat[8]);

			float rotDet = determinant(
				col0.x, col1.x, col2.x,
				col0.y, col1.y, col2.y,
				col0.z, col1.z, col2.z
			);

			//if (rotDet < 0.f)
			//{
			//	vMat[0] = -vMat[0];
			//	vMat[1] = -vMat[1];
			//	vMat[2] = -vMat[2];
			//	rotDet = -rotDet;
			//}
			if (fabsf(rotDet - 1.0f) <= 0.01f)
			{
				quaternion4f rotation(
					col0.x, col1.x, col2.x,
					col0.y, col1.y, col2.y,
					col0.z, col1.z, col2.z
				);
				outRotation[aId] = rotation;
			}
		}		
	}

};


class TransformationExtractor
{
public:
	thrust::device_ptr<unsigned int> nodeTypes;
	
	thrust::device_ptr<unsigned int> outNeighborTypeKeys;
	thrust::device_ptr<unsigned int> outNeighborTypeVals;

	thrust::device_ptr<float3> translation;
	thrust::device_ptr<quaternion4f> rotation;

	thrust::device_ptr<float3> outTranslation;
	thrust::device_ptr<quaternion4f> outRotation;


	TransformationExtractor(
		thrust::device_ptr<unsigned int> aNodeTypes,
		thrust::device_ptr<unsigned int> aOutNbrTypeKeys,
		thrust::device_ptr<unsigned int> aOutNbrTypeVals,
		thrust::device_ptr<float3> aTranslation,
		thrust::device_ptr<quaternion4f> aRotation,
		thrust::device_ptr<float3> aOutTranslation,
		thrust::device_ptr<quaternion4f> aOutRotation
	) :
		nodeTypes(aNodeTypes),
		outNeighborTypeKeys(aOutNbrTypeKeys),
		outNeighborTypeVals(aOutNbrTypeVals),
		translation(aTranslation),
		rotation(aRotation),
		outTranslation(aOutTranslation),
		outRotation(aOutRotation)
	{}

	template <typename Tuple>
	__host__ __device__	void operator()(Tuple t)
	{
		const unsigned int nodeId1 = thrust::get<0>(t);
		const unsigned int nodeId2 = thrust::get<1>(t);
		const unsigned int outId = (unsigned)thrust::get<2>(t);


		outNeighborTypeKeys[outId] = nodeTypes[nodeId1];
		outNeighborTypeVals[outId] = nodeTypes[nodeId2];

		quaternion4f rot = rotation[nodeId1];
		outTranslation[outId] = transformVec(rot.conjugate(), translation[nodeId2] - translation[nodeId1]);
		quaternion4f rot2 = rotation[nodeId2];
		outRotation[outId] = rot2.conjugate() * rot;
	}

};


__host__ void Wiggle::init(WFObject & aObj, Graph & aGraph)
{
	float3 minBound, maxBound;
	ObjectBoundsExporter()(aObj, minBound, maxBound);
	spatialTolerance = std::max(0.05f * len(maxBound - minBound), spatialTolerance);


	//Unpack and upload the vertex buffer
	thrust::host_vector<uint2> vertexRangesHost;
	thrust::host_vector<float3> vertexBufferHost;

	VertexBufferUnpacker unpackVertices;
	unpackVertices(aObj, vertexRangesHost, vertexBufferHost);

	thrust::device_vector<uint2> vertexRangesDevice(vertexRangesHost);
	thrust::device_vector<float3> vertexBufferDevice(vertexBufferHost);


//#ifdef _DEBUG
//	outputDeviceVector("vertex ranges: ", vertexRangesDevice);
//	outputDeviceVector("vertex buffer: ", vertexBufferDevice);
//#endif

	//Use PCA to compute local coordiante system for each object
	thrust::device_vector<float3> outTranslation(aObj.getNumObjects());
	thrust::device_vector<quaternion4f> outRotation(aObj.getNumObjects());

	thrust::device_vector<double> tmpCovMatrix(aObj.getNumObjects() * 3 * 3, 0.f);
	thrust::device_vector<double> tmpDiagonalW(aObj.getNumObjects() * 3);
	thrust::device_vector<double> tmpMatrixV(aObj.getNumObjects() * 3 * 3);
	thrust::device_vector<double> tmpVecRV(aObj.getNumObjects() * 3);

	LocalCoordsEstimator estimateT(
		thrust::raw_pointer_cast(vertexRangesDevice.data()),
		thrust::raw_pointer_cast(vertexBufferDevice.data()),
		thrust::raw_pointer_cast(tmpCovMatrix.data()),
		thrust::raw_pointer_cast(tmpDiagonalW.data()),
		thrust::raw_pointer_cast(tmpMatrixV.data()),
		thrust::raw_pointer_cast(tmpVecRV.data()),
		thrust::raw_pointer_cast(outTranslation.data()),
		thrust::raw_pointer_cast(outRotation.data())
	);

	thrust::counting_iterator<size_t> first(0u);
	thrust::counting_iterator<size_t> last(aObj.getNumObjects());

	thrust::for_each(first, last, estimateT);

//#ifdef _DEBUG
//	outputDeviceVector("translations: ", outTranslation);
//	outputDeviceVector("rotations: ", outRotation);
//#endif

	//Extract and upload node type information
	thrust::host_vector<unsigned int> nodeTypesHost(aGraph.numNodes(), (unsigned int)aObj.materials.size());
	for (size_t nodeId = 0; nodeId < aObj.objects.size(); ++nodeId)
	{
		size_t faceId = aObj.objects[nodeId].x;
		size_t materialId = aObj.faces[faceId].material;
		nodeTypesHost[nodeId] = (unsigned int)materialId;
	}
	thrust::device_vector<unsigned int> nodeTypes(nodeTypesHost);

	thrust::device_vector<unsigned int> neighborTypeKeys(aGraph.numEdges() * 2u);
	thrust::device_vector<unsigned int> neighborTypeVals(aGraph.numEdges() * 2u);
	thrust::device_vector<float3> relativeTranslation(aGraph.numEdges() * 2u);
	thrust::device_vector<quaternion4f> relativeRotation(aGraph.numEdges() * 2u);

	TransformationExtractor extractRelativeT(
		nodeTypes.data(),
		neighborTypeKeys.data(),
		neighborTypeVals.data(),
		outTranslation.data(),
		outRotation.data(),
		relativeTranslation.data(),
		relativeRotation.data()
	);

	thrust::counting_iterator<size_t> lastEdge(aGraph.numEdges() * 2u);

	thrust::for_each(
		thrust::make_zip_iterator(thrust::make_tuple(aGraph.adjacencyKeys.begin(), aGraph.adjacencyVals.begin(), first)),
		thrust::make_zip_iterator(thrust::make_tuple(aGraph.adjacencyKeys.end(), aGraph.adjacencyVals.end(), lastEdge)),
		extractRelativeT);


	if(mNeighborTypeKeys.size() == 0u)
	{ 
		//first call of init
		mNeighborTypeKeys = thrust::host_vector<unsigned int>(neighborTypeKeys);
		mNeighborTypeVals = thrust::host_vector<unsigned int>(neighborTypeVals);
		mRelativeTranslation = thrust::host_vector<float3>(relativeTranslation);
		mRelativeRotation = thrust::host_vector<quaternion4f>(relativeRotation);
	}
	else
	{
		//init already called, append new data
		size_t oldCount = mNeighborTypeKeys.size();
		mNeighborTypeKeys.resize(oldCount + neighborTypeKeys.size());
		mNeighborTypeVals.resize(oldCount + neighborTypeVals.size());
		mRelativeTranslation.resize(oldCount + relativeTranslation.size());
		mRelativeRotation.resize(oldCount + relativeRotation.size());

		thrust::copy(neighborTypeKeys.begin(), neighborTypeKeys.end(), mNeighborTypeKeys.begin() + oldCount);
		thrust::copy(neighborTypeVals.begin(), neighborTypeVals.end(), mNeighborTypeVals.begin() + oldCount);
		thrust::copy(relativeTranslation.begin(), relativeTranslation.end(), mRelativeTranslation.begin() + oldCount);
		thrust::copy(relativeRotation.begin(), relativeRotation.end(), mRelativeRotation.begin() + oldCount);
	}

	//sort by node type
	thrust::sort_by_key(
		mNeighborTypeKeys.begin(),
		mNeighborTypeKeys.end(),
		thrust::make_zip_iterator(thrust::make_tuple(mNeighborTypeVals.begin(), mRelativeTranslation.begin(), mRelativeRotation.begin()))
		);

	//setup search intervals for each node type
	mIntervals.resize(aObj.materials.size() + 1u, 0u);
	for (size_t i = 0u; i < mNeighborTypeKeys.size() - 1u; ++i)
	{
		if (mNeighborTypeKeys[i] < mNeighborTypeKeys[i + 1u])
		{
			mIntervals[mNeighborTypeKeys[i] + 1] = (unsigned)i + 1u;
		}
	}
	//last element
	if (mNeighborTypeKeys.size() > 0u)
		mIntervals[mNeighborTypeKeys[mNeighborTypeKeys.size() - 1u] + 1] = (unsigned)mNeighborTypeKeys.size();

	//fill gaps due to missing node types
	for (size_t i = 1u; i < mIntervals.size(); ++i)
	{
		mIntervals[i] = std::max(mIntervals[i - 1u], mIntervals[i]);
	}

#ifdef _DEBUG
	outputHostVector("wiggle type key intervals: ", mIntervals);
	outputHostVector("wiggle keys: ", mNeighborTypeKeys);
	outputHostVector("wiggle vals: ", mNeighborTypeVals);
	outputHostVector("translations: ", mRelativeTranslation);
	outputHostVector("rotations: ", mRelativeRotation);
#endif
}

__host__ void Wiggle::fixRelativeTransformations(WFObject & aObj, Graph & aGraph)
{
	//Unpack and upload the vertex buffer
	thrust::host_vector<uint2> vertexRangesHost;
	thrust::host_vector<float3> vertexBufferHost;

	VertexBufferUnpacker unpackVertices;
	unpackVertices(aObj, vertexRangesHost, vertexBufferHost);

	thrust::device_vector<uint2> vertexRangesDevice(vertexRangesHost);
	thrust::device_vector<float3> vertexBufferDevice(vertexBufferHost);


	size_t numNodes = aObj.objects.size();
	thrust::host_vector<unsigned int> visited(numNodes, 0u);
	thrust::host_vector<unsigned int> intervalsHost(aGraph.intervals);
	thrust::host_vector<unsigned int> adjacencyValsHost(aGraph.adjacencyVals);

	//Extract and upload node type information
	thrust::host_vector<unsigned int> nodeTypesHost(aGraph.numNodes(), (unsigned int)aObj.materials.size());
	for (size_t nodeId = 0; nodeId < aObj.objects.size(); ++nodeId)
	{
		size_t faceId = aObj.objects[nodeId].x;
		size_t materialId = aObj.faces[faceId].material;
		nodeTypesHost[nodeId] = (unsigned int)materialId;
	}

	std::deque<unsigned int> frontier;
	frontier.push_back(0u);
	visited[0u] = 1u;
	while (!frontier.empty())
	{
		const unsigned int nodeId = frontier.front();
		frontier.pop_front();
		
		processNeighbors(
			aObj,
			nodeId,
			visited,
			intervalsHost,
			adjacencyValsHost,
			nodeTypesHost);

		for (unsigned int nbrId = intervalsHost[nodeId]; nbrId < intervalsHost[nodeId + 1]; ++nbrId)
		{
			const unsigned int nodeId = adjacencyValsHost[nbrId];
			if (visited[nodeId] == 0u)
			{
				frontier.push_back(nodeId);
				visited[nodeId] = 1u;
			}
		}
	}

}

__host__ void Wiggle::processNeighbors(
	WFObject&							aObj,
	unsigned int						aObjId,
	thrust::host_vector<unsigned int>&	visited,
	thrust::host_vector<unsigned int>&	intervalsHost,
	thrust::host_vector<unsigned int>&	adjacencyValsHost,
	thrust::host_vector<unsigned int>&	nodeTypeIds)
{
	const unsigned int nbrCount = intervalsHost[aObjId + 1u] - intervalsHost[aObjId];

	if (nbrCount == 0)
		return;

	const unsigned int nodeCount = nbrCount + 1u;
	thrust::host_vector<unsigned int> nodeIds(nodeCount, aObjId);
	thrust::copy(adjacencyValsHost.begin() + intervalsHost[aObjId], adjacencyValsHost.begin() + intervalsHost[aObjId + 1], nodeIds.begin() + 1u);
	
	unsigned int vtxCount = 0u;
	for (unsigned int i = 0; i < nodeIds.size(); i++)
	{
		vtxCount += 3 * (aObj.objects[nodeIds[i]].y - aObj.objects[nodeIds[i]].x);
	}

	//Unpack the vertex buffer
	thrust::host_vector<float3> vertexBufferHost(vtxCount);
	thrust::host_vector<uint2> vtxRanges(nodeCount);
	unsigned int currentVtxId = 0u;
	for (unsigned int i = 0; i < nodeIds.size(); i++)
	{
		vtxRanges[i].x = currentVtxId;
		for (int faceId = aObj.objects[nodeIds[i]].x; faceId < aObj.objects[nodeIds[i]].y; ++faceId)
		{
			WFObject::Face face = aObj.faces[faceId];
			vertexBufferHost[currentVtxId++] = aObj.vertices[aObj.faces[faceId].vert1];
			vertexBufferHost[currentVtxId++] = aObj.vertices[aObj.faces[faceId].vert2];
			vertexBufferHost[currentVtxId++] = aObj.vertices[aObj.faces[faceId].vert3];
		}
		vtxRanges[i].y = currentVtxId;
	}


	//Use PCA to compute local coordiante system for each object
	thrust::host_vector<float3> translations(nodeCount);
	thrust::host_vector<quaternion4f> rotations(nodeCount);
	thrust::host_vector<double> tmpCovMatrix(nodeCount * 3 * 3, 0.f);
	thrust::host_vector<double> tmpDiagonalW(nodeCount * 3);
	thrust::host_vector<double> tmpMatrixV(nodeCount * 3 * 3);
	thrust::host_vector<double> tmpVecRV(nodeCount * 3);

	LocalCoordsEstimator estimateT(
		thrust::raw_pointer_cast(vtxRanges.data()),
		thrust::raw_pointer_cast(vertexBufferHost.data()),
		thrust::raw_pointer_cast(tmpCovMatrix.data()),
		thrust::raw_pointer_cast(tmpDiagonalW.data()),
		thrust::raw_pointer_cast(tmpMatrixV.data()),
		thrust::raw_pointer_cast(tmpVecRV.data()),
		thrust::raw_pointer_cast(translations.data()),
		thrust::raw_pointer_cast(rotations.data())
	);

	//thrust::counting_iterator<size_t> first(0u);
	//thrust::counting_iterator<size_t> last(nodeCount);
	//thrust::for_each(first, last, estimateT);

	for (unsigned int i = 0u; i < nodeCount; ++i)
	{
		estimateT(i);
	}

	for (unsigned int i = 1; i < nodeIds.size(); i++)
	{
		const unsigned int nbrNodeId = nodeIds[i];
		if (visited[nbrNodeId])
			continue;

		const unsigned int nodeId1 = nodeIds[0];
		const unsigned int nodeId2 = nbrNodeId;

		const unsigned int typeId1 = nodeTypeIds[nodeId1];
		const unsigned int typeId2 = nodeTypeIds[nodeId2];

		quaternion4f rot = rotations[0];
		float3 relativeT = transformVec(rot.conjugate(), translations[i] - translations[0]);
		quaternion4f relativeR = rotations[i].conjugate() * rot;

		float3 bestT = relativeT;
		quaternion4f bestR = relativeR;

		findBestMatch(typeId1, typeId2, relativeT, relativeR, bestT, bestR);
		const float angleDelta = fabsf(fabsf((bestR * relativeR.conjugate()).w) - 1.f);
		if (angleDelta < angleTolerance)
			continue;
		//transformObj(aObj, nodeId1, -translations[0], rotations[0].conjugate());
		//transformObj(aObj, nodeId2, -translations[1], rotations[i].conjugate());
		transformObj(aObj, nodeId2, -translations[i], bestR * relativeR.conjugate());
	}

}

__host__ void Wiggle::findBestMatch(
	unsigned int		aTypeId1,
	unsigned int		aTypeId2,
	const float3&		aTranslation,
	const quaternion4f&	aRotation,
	float3&				oTranslation,
	quaternion4f&		oRotation)
{
	//float bestSpatialDist = FLT_MAX;
	float bestAngleDist = FLT_MAX;
	for (unsigned int id = mIntervals[aTypeId1]; id < mIntervals[aTypeId1 + 1]; id++)
	{
		if (mNeighborTypeVals[id] != aTypeId2)
			continue;
		const float3 delta = mRelativeTranslation[id] - aTranslation;
		const float currentSpatialDist = len(delta);
		const float angleDelta = fabsf(fabsf((aRotation *  mRelativeRotation[id].conjugate()).w) - 1.f);
		if (currentSpatialDist < spatialTolerance && angleDelta < bestAngleDist)
		{
			//bestSpatialDist = currentSpatialDist;
			oTranslation = mRelativeTranslation[id];
			
			bestAngleDist = angleDelta;
			oRotation = mRelativeRotation[id];
		}
	}
}

__host__ void Wiggle::transformObj(
	WFObject & aObj,
	unsigned int aObjId,
	const float3 & aTranslation0toB,
	const quaternion4f & aRotationBtoAtoC)
{
	thrust::host_vector<unsigned int> processed(aObj.getNumVertices(), 0u);
	for (int faceId = aObj.objects[aObjId].x; faceId < aObj.objects[aObjId].y; ++faceId)
	{
		WFObject::Face face = aObj.faces[faceId];
		size_t vtxId1 = aObj.faces[faceId].vert1;
		size_t vtxId2 = aObj.faces[faceId].vert2;
		size_t vtxId3 = aObj.faces[faceId].vert3;
		if (processed[vtxId1] == 0u)
		{
			processed[vtxId1] = 1u;
			float3 vtx = aObj.vertices[vtxId1];
			aObj.vertices[vtxId1] = transformVec(aRotationBtoAtoC, vtx + aTranslation0toB) - aTranslation0toB;
		}
		if (processed[vtxId2] == 0u)
		{
			processed[vtxId2] = 1u;
			float3 vtx = aObj.vertices[vtxId2];
			aObj.vertices[vtxId2] = transformVec(aRotationBtoAtoC, vtx + aTranslation0toB) - aTranslation0toB;

		}
		if (processed[vtxId3] == 0u)
		{
			processed[vtxId3] = 1u;
			float3 vtx = aObj.vertices[vtxId3];
			aObj.vertices[vtxId3] = transformVec(aRotationBtoAtoC, vtx + aTranslation0toB) - aTranslation0toB;
		}
	}

}