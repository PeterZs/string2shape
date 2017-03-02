#include "pch.h"
#include "UniformGridSortBuilder.h"

#include "Algebra.h"
#include "UniformGrid.h"

#include "Primitive.h"
#include "BBox.h"

#include <thrust/device_vector.h>
#include <thrust/fill.h>
#include <thrust/reduce.h>
#include <thrust/transform.h>
#include <thrust/scan.h>
#include <thrust/sort.h>
#include <thrust/iterator/counting_iterator.h>
#include <thrust/iterator/zip_iterator.h>

class FragmentCounter
{
public:
	int							gridRes[3];
	const float3                minBound;
	const float3                cellSizeRCP;
	thrust::device_ptr<float3>  vertexArray;

	FragmentCounter(
		int aGridResX, int aGridResY, int aGridResZ,
		float3 aMinBound,
		float3 aCellSizeRCP,
		thrust::device_ptr<float3> aVtxArray): 		 
		minBound(aMinBound), 
		cellSizeRCP(aCellSizeRCP), 
		vertexArray(aVtxArray)
	{
		gridRes[0] = aGridResX;
		gridRes[1] = aGridResY;
		gridRes[2] = aGridResZ;
	}
	
	__host__ __device__	int operator()(const uint3& aTriVtxIds)
	{
		Triangle prim;
		prim.vtx[0] = vertexArray[aTriVtxIds.x];
		prim.vtx[1] = vertexArray[aTriVtxIds.y];
		prim.vtx[2] = vertexArray[aTriVtxIds.z];

		BBox bounds = BBoxExtractor<Triangle>::get(prim);

		float3 minCellIdf = (bounds.vtx[0] - minBound) * cellSizeRCP;
		const float3 maxCellIdPlus1f = (bounds.vtx[1] - minBound) * cellSizeRCP + rep(1.f);

		const int minCellIdX = max(0, (int)(minCellIdf.x));
		const int minCellIdY = max(0, (int)(minCellIdf.y));
		const int minCellIdZ = max(0, (int)(minCellIdf.z));

		const int maxCellIdP1X = min(gridRes[0], (int)(maxCellIdPlus1f.x));
		const int maxCellIdP1Y = min(gridRes[1], (int)(maxCellIdPlus1f.y));
		const int maxCellIdP1Z = min(gridRes[2], (int)(maxCellIdPlus1f.z));
		const int numCells =
			(maxCellIdP1X - minCellIdX)
			* (maxCellIdP1Y - minCellIdY)
			* (maxCellIdP1Z - minCellIdZ);

		return numCells;
	}

};

//////////////////////////////////////////////////////////////////////////
//axis tests
//////////////////////////////////////////////////////////////////////////

__host__ __device__ bool axisTest(
	const float a,
	const float b,
	const float fa,
	const float fb,
	const float v0a,
	const float v0b,
	const float v1a,
	const float v1b,
	const float aCellSizeHALFa,
	const float aCellSizeHALFb)
{
	const float p0 = a * v0a + b * v0b;
	const float p1 = a * v1a + b * v1b;

	const float minP = fminf(p0, p1);
	const float maxP = fmaxf(p0, p1);

	const float rad = fa * aCellSizeHALFa + fb * aCellSizeHALFb;

	return !(minP > rad + EPS || maxP + EPS < -rad);

}

#define AXISTEST_X01(e, fe, v0, v1, v2, s)                                     \
    axisTest(e.z, -e.y, fe.z, fe.y, v0.y, v0.z, v2.y, v2.z, s.y, s.z)

#define AXISTEST_X2(e, fe, v0, v1, v2, s)                                      \
    axisTest(e.z, -e.y, fe.z, fe.y, v0.y, v0.z, v1.y, v1.z, s.y, s.z)

#define AXISTEST_Y02(e, fe, v0, v1, v2, s)                                     \
    axisTest(-e.z, e.x, fe.z, fe.x, v0.x, v0.z, v2.x, v2.z, s.x, s.z)

#define AXISTEST_Y1(e, fe, v0, v1, v2, s)                                      \
    axisTest(-e.z, e.x, fe.z, fe.x, v0.x, v0.z, v1.x, v1.z, s.x, s.z)

#define AXISTEST_Z12(e, fe, v0, v1, v2, s)                                     \
    axisTest(e.y, -e.x, fe.y, fe.x, v1.x, v1.y, v2.x, v2.y, s.x, s.y)

#define AXISTEST_Z0(e, fe, v0, v1, v2, s)                                      \
    axisTest(e.y, -e.x, fe.y, fe.x, v0.x, v0.y, v1.x, v1.y, s.x, s.y)

//////////////////////////////////////////////////////////////////////////

class FragmentWriter
{
public:
	int							gridRes[3];
	const float3                minBound;
	const float3                cellSize;
	const float3                cellSizeRCP;
	thrust::device_ptr<float3>  vertexArray;
	thrust::device_ptr<uint>	outKeys;
	thrust::device_ptr<uint>	outValues;

	FragmentWriter(
		int aGridResX, int aGridResY, int aGridResZ,
		float3 aMinBound,
		float3 aCellSize,
		float3 aCellSizeRCP,
		thrust::device_ptr<float3> aVtxArray,
		thrust::device_ptr<uint> aKeys,
		thrust::device_ptr<uint> aVals
		) :
		minBound(aMinBound),
		cellSize(aCellSize),
		cellSizeRCP(aCellSizeRCP),
		vertexArray(aVtxArray),
		outKeys(aKeys),
		outValues(aVals)
	{
		gridRes[0] = aGridResX;
		gridRes[1] = aGridResY;
		gridRes[2] = aGridResZ;
	}

	template <typename Tuple>
	__host__ __device__	void operator()(Tuple t)
	{
		const uint3 aTriVtxIds = thrust::get<0>(t);
		const unsigned int startPosition = thrust::get<1>(t);
		const size_t triangleId = thrust::get<2>(t);

		Triangle triangle;
		triangle.vtx[0] = vertexArray[aTriVtxIds.x];
		triangle.vtx[1] = vertexArray[aTriVtxIds.y];
		triangle.vtx[2] = vertexArray[aTriVtxIds.z];

		BBox bounds = BBoxExtractor<Triangle>::get(triangle);

		float3 minCellIdf = (bounds.vtx[0] - minBound) * cellSizeRCP;
		const float3 maxCellIdPlus1f = (bounds.vtx[1] - minBound) * cellSizeRCP + rep(1.f);

		const int minCellIdX = max(0, (int)(minCellIdf.x));
		const int minCellIdY = max(0, (int)(minCellIdf.y));
		const int minCellIdZ = max(0, (int)(minCellIdf.z));

		const int maxCellIdP1X = min(gridRes[0], (int)(maxCellIdPlus1f.x));
		const int maxCellIdP1Y = min(gridRes[1], (int)(maxCellIdPlus1f.y));
		const int maxCellIdP1Z = min(gridRes[2], (int)(maxCellIdPlus1f.z));

		unsigned int nextSlot = startPosition;
		const float3 normal =
			~((triangle.vtx[1] - triangle.vtx[0]) %
			(triangle.vtx[2] - triangle.vtx[0]));

		const float3 gridCellSizeHALF = cellSize * 0.505f; //1% extra as epsilon
		float3 minCellCenter;
		minCellCenter.x = (float)(minCellIdX);
		minCellCenter.y = (float)(minCellIdY);
		minCellCenter.z = (float)(minCellIdZ);
		minCellCenter = minCellCenter * cellSize;
		minCellCenter = minCellCenter + minBound + gridCellSizeHALF;

		float3 cellCenter;
		cellCenter.z = minCellCenter.z - cellSize.z;

		for (int z = minCellIdZ; z < maxCellIdP1Z; ++z)
		{
			cellCenter.z += cellSize.z;
			cellCenter.y = minCellCenter.y - cellSize.y;

			for (int y = minCellIdY; y < maxCellIdP1Y; ++y)
			{
				cellCenter.y += cellSize.y;
				cellCenter.x = minCellCenter.x - cellSize.x;

				for (int x = minCellIdX; x < maxCellIdP1X; ++x, ++nextSlot)
				{
					cellCenter.x += cellSize.x;

					//////////////////////////////////////////////////////////////////////////
					//coordinate transform origin -> cellCenter
					const float3 v0 = triangle.vtx[0] - cellCenter;
					const float3 v1 = triangle.vtx[1] - cellCenter;
					const float3 v2 = triangle.vtx[2] - cellCenter;
					const float3 e0 = v1 - v0;
					const float3 e1 = v2 - v1;
					const float3 e2 = v0 - v2;

					bool passedAllTests = true;
					//////////////////////////////////////////////////////////////////////////
					//Plane/box overlap test
					float3 vmin, vmax;
					vmin.x = (normal.x > 0.f) ? -gridCellSizeHALF.x : gridCellSizeHALF.x;
					vmin.y = (normal.y > 0.f) ? -gridCellSizeHALF.y : gridCellSizeHALF.y;
					vmin.z = (normal.z > 0.f) ? -gridCellSizeHALF.z : gridCellSizeHALF.z;

					vmax = -vmin;
					vmax = vmax - v0;
					vmin = vmin - v0;

					passedAllTests = passedAllTests && dot(normal, vmin) <= 0.f && dot(normal, vmax) > 0.f;
					//Note: early exit here makes the code slower (CUDA 7.5, GTX 970)
					//////////////////////////////////////////////////////////////////////////
					//9 tests for separating axis
					float3 fe;
					fe.x = fabsf(e0.x);
					fe.y = fabsf(e0.y);
					fe.z = fabsf(e0.z);

					passedAllTests = passedAllTests && AXISTEST_X01(e0, fe, v0, v1, v2, gridCellSizeHALF);
					passedAllTests = passedAllTests && AXISTEST_Y02(e0, fe, v0, v1, v2, gridCellSizeHALF);
					passedAllTests = passedAllTests && AXISTEST_Z12(e0, fe, v0, v1, v2, gridCellSizeHALF);

					fe.x = fabsf(e1.x);
					fe.y = fabsf(e1.y);
					fe.z = fabsf(e1.z);

					passedAllTests = passedAllTests && AXISTEST_X01(e1, fe, v0, v1, v2, gridCellSizeHALF);
					passedAllTests = passedAllTests && AXISTEST_Y02(e1, fe, v0, v1, v2, gridCellSizeHALF);
					passedAllTests = passedAllTests && AXISTEST_Z0(e1, fe, v0, v1, v2, gridCellSizeHALF);

					fe.x = fabsf(e2.x);
					fe.y = fabsf(e2.y);
					fe.z = fabsf(e2.z);

					passedAllTests = passedAllTests && AXISTEST_X2(e2, fe, v0, v1, v2, gridCellSizeHALF);
					passedAllTests = passedAllTests && AXISTEST_Y1(e2, fe, v0, v1, v2, gridCellSizeHALF);
					passedAllTests = passedAllTests && AXISTEST_Z12(e2, fe, v0, v1, v2, gridCellSizeHALF);

					if (!passedAllTests)
					{
						outKeys[nextSlot] =	(uint)(gridRes[0] * gridRes[1] * gridRes[2]);

						outValues[nextSlot] = (uint)triangleId;
						continue;
					}

					outKeys[nextSlot] = x +	y * gridRes[0] + z * (gridRes[1] * gridRes[2]);

					outValues[nextSlot] = (uint)triangleId;

				}//end for z
			}//end for y
		}//end for x
	}

};

class CellExtractor
{
public:
	int			gridRes[3];
	uint2*		cells;

	CellExtractor(
		int aGridResX, int aGridResY, int aGridResZ,
		thrust::device_ptr<uint2> aCellsPtr)	
	{
		gridRes[0] = aGridResX;
		gridRes[1] = aGridResY;
		gridRes[2] = aGridResZ;
		cells = thrust::raw_pointer_cast(aCellsPtr);
	}

	template <typename Tuple>
	__host__ __device__	void operator()(Tuple t)
	{
		const unsigned int myCellIndex = thrust::get<0>(t);
		const unsigned int nextCellIndex = thrust::get<1>(t);
		const size_t myId = thrust::get<2>(t);
		if (myCellIndex >= (unsigned int)gridRes[0] * gridRes[1] * gridRes[2])
			return;
		if (myCellIndex != nextCellIndex)
		{
			//end of range for the cell at myCellIndex
			cells[myCellIndex].y = (unsigned int)myId + 1u;
			//start of range for the cell at nextCellIndex
			cells[nextCellIndex].x = (unsigned int)myId + 1u;
		}
	}

};

__host__ UniformGrid UniformGridSortBuilder::build(WFObject & aGeometry, const int aResX, const int aResY, const int aResZ)
{
	UniformGrid oGrid;
	//initialize grid resolution
	oGrid.res[0] = thrust::max<int>(aResX, 1);
	oGrid.res[1] = thrust::max<int>(aResY, 1);
	oGrid.res[2] = thrust::max<int>(aResZ, 1);
	//allocate grid cells
	oGrid.cells = thrust::device_vector<uint2>(oGrid.res[0] * oGrid.res[1] * oGrid.res[2]);
	//initialize empy cells
	thrust::device_ptr<uint2> dev_ptr_uint2 = oGrid.cells.data();
	uint2 * raw_ptr_uint2 = thrust::raw_pointer_cast(dev_ptr_uint2);
	uint *  raw_ptr_uint = (uint*)raw_ptr_uint2;
	thrust::device_ptr<uint> dev_ptr_uint(raw_ptr_uint);
	thrust::fill(dev_ptr_uint, dev_ptr_uint + 2 * oGrid.res[0] * oGrid.res[1] * oGrid.res[2], 0u);

	//compute vertex index buffer for the triangles
	std::vector<uint3> host_indices(aGeometry.faces.size());
	for (size_t i = 0; i < aGeometry.faces.size(); i++)
	{
		host_indices[i].x = (unsigned int)aGeometry.faces[i].vert1;
		host_indices[i].y = (unsigned int)aGeometry.faces[i].vert2;
		host_indices[i].z = (unsigned int)aGeometry.faces[i].vert3;
	}
	//copy the vertex index buffer to the device
	thrust::device_vector<uint3> device_indices(host_indices.begin(), host_indices.end());
	//copy the vertex buffer to the device
	thrust::device_vector<float3> device_vertices(aGeometry.vertices.begin(), aGeometry.vertices.end());
	//compute scene bounding box
	oGrid.vtx[0] = thrust::reduce(device_vertices.begin(), device_vertices.end(), make_float3( FLT_MAX,  FLT_MAX,  FLT_MAX), binary_float3_min());
	oGrid.vtx[1] = thrust::reduce(device_vertices.begin(), device_vertices.end(), make_float3(-FLT_MAX, -FLT_MAX,- FLT_MAX), binary_float3_max());

	//count triangle-cell intersections
	thrust::device_vector<unsigned int> fragment_counts(device_indices.size() + 1);
	FragmentCounter frag_count(
		oGrid.res[0], oGrid.res[1], oGrid.res[2],
		oGrid.vtx[0],
		oGrid.getCellSizeRCP(),
		device_vertices.data()
	);

	thrust::transform(device_indices.begin(), device_indices.end(), fragment_counts.begin(), frag_count);

	thrust::exclusive_scan(fragment_counts.begin(), fragment_counts.end(), fragment_counts.begin());

	size_t num_fragments = fragment_counts[device_indices.size()];

	//allocate cell index and triangle index buffers
	thrust::device_vector<uint> fragment_keys(num_fragments);
	oGrid.primitives = thrust::device_vector<uint> (num_fragments);//fragment_vals

	//write triangle-cell pairs
	FragmentWriter frag_write(
		oGrid.res[0], oGrid.res[1], oGrid.res[2],
		oGrid.vtx[0],
		oGrid.getCellSize(),
		oGrid.getCellSizeRCP(),
		device_vertices.data(),
		fragment_keys.data(),
		oGrid.primitives.data()
	);

	thrust::counting_iterator<size_t> first(0u);
	thrust::counting_iterator<size_t> last(device_indices.size());

	thrust::for_each(
		thrust::make_zip_iterator(thrust::make_tuple(device_indices.begin(), fragment_counts.begin(), first)),
		thrust::make_zip_iterator(thrust::make_tuple(device_indices.end(), fragment_counts.end() - 1u, last)),
		frag_write);

	//sort the pairs
	thrust::sort_by_key(fragment_keys.begin(), fragment_keys.end(), oGrid.primitives.begin());
	
	//initilize the grid cells
	CellExtractor extract_ranges(
		oGrid.res[0], oGrid.res[1], oGrid.res[2],
		oGrid.cells.data()
	);

	thrust::counting_iterator<size_t> first_pair(0u);
	thrust::counting_iterator<size_t> last_pair(num_fragments - 1);

	thrust::for_each(
		thrust::make_zip_iterator(thrust::make_tuple(fragment_keys.begin(), fragment_keys.begin() + 1, first_pair)),
		thrust::make_zip_iterator(thrust::make_tuple(fragment_keys.end() - 1, fragment_keys.end(), last_pair)),
		extract_ranges);

	return oGrid;
}
