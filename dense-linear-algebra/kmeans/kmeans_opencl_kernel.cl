#ifndef _KMEANS_CUDA_KERNEL_H_
#define _KMEANS_CUDA_KERNEL_H_

#ifndef FLT_MAX
#define FLT_MAX 3.40282347e+38
#endif

// FIXME: Make this a runtime selectable variable!
#define ASSUMED_NR_CLUSTERS 32

// t_features has the layout dim0[points 0-m-1]dim1[ points 0-m-1]...
//texture<float, 1, cudaReadModeElementType> t_features;
// t_features_flipped has the layout point0[dim 0-n-1]point1[dim 0-n-1]
//texture<float, 1, cudaReadModeElementType> t_features_flipped;
//texture<float, 1, cudaReadModeElementType> t_clusters;


//__constant__ float c_clusters[ASSUMED_NR_CLUSTERS*34];		/* constant memory for cluster centers */

/* ----------------- invert_mapping() --------------------- */
/* inverts data array from row-major to column-major.

   [p0,dim0][p0,dim1][p0,dim2] ... 
   [p1,dim0][p1,dim1][p1,dim2] ... 
   [p2,dim0][p2,dim1][p2,dim2] ... 
   to
   [dim0,p0][dim0,p1][dim0,p2] ...
   [dim1,p0][dim1,p1][dim1,p2] ...
   [dim2,p0][dim2,p1][dim2,p2] ...
 */
__kernel void invert_mapping(__global float *input,			/* original */
		__global float *output,			/* inverted */
		int npoints,				/* npoints */
		int nfeatures)			/* nfeatures */
{
	int point_id = get_local_id(0) + get_local_size(0)*get_group_id(0);	/* id of thread */
	int i;

	if(point_id < npoints){
		for(i=0;i<nfeatures;i++)
			output[point_id + npoints*i] = input[point_id*nfeatures + i];
	}
	return;
}
/* ----------------- invert_mapping() end --------------------- */

/* to turn on the GPU delta and center reduction */
//#define GPU_DELTA_REDUCTION
//#define GPU_NEW_CENTER_REDUCTION
//#define THREADS_PER_BLOCK 256

/* ----------------- kmeansPoint() --------------------- */
/* find the index of nearest cluster centers and change membership*/
	__kernel void
kmeansPoint(__global float  *features,			/* in: [npoints*nfeatures] */
		__global float  *features_flipped,
		int     nfeatures,
		int     npoints,
		int     nclusters,
		__global int    *membership,
		__constant float  *clusters
#ifdef GPU_NEW_CENTER_REDUCTION
		, __global float  *block_clusters
#endif
#ifdef GPU_DELTA_REDUCTION
		, __global int    *block_deltas
#endif
	   ) 
{

	// block ID
	const unsigned int block_id = get_num_groups(0)*get_group_id(1)+get_group_id(0);
	// point/thread ID  
	const unsigned int point_id = block_id*get_local_size(0)*get_local_size(1) + get_local_id(0);

	int  index = -1;

	if (point_id < npoints)
	{
		int i, j;
		float min_dist = FLT_MAX;
		float dist;													/* distance square between a point to cluster center */

		/* find the cluster center id with min distance to pt */
		for (i=0; i<nclusters; i++) {
			int cluster_base_index = i*nfeatures;					/* base index of cluster centers for inverted array */			
			float ans=0.0;												/* Euclidean distance sqaure */

			for (j=0; j < nfeatures; j++)
			{					
				int addr = point_id + j*npoints;					/* appropriate index of data point */
				float diff = (features[addr] -
						clusters[cluster_base_index + j]);	/* distance between a data point to cluster centers */
				ans += diff*diff;									/* sum of squares */
			}
			dist = ans;		

			/* see if distance is smaller than previous ones:
			   if so, change minimum distance and save index of cluster center */
			if (dist < min_dist) {
				min_dist = dist;
				index    = i;
			}
		}
	}


#ifdef GPU_DELTA_REDUCTION
	// count how many points are now closer to a different cluster center	
	__local int deltas[THREADS_PER_BLOCK];
	if(get_local_id(0) < THREADS_PER_BLOCK) {
		deltas[get_local_id(0)] = 0;
	}
#endif
	if (point_id < npoints)
	{
#ifdef GPU_DELTA_REDUCTION
		/* if membership changes, increase delta by 1 */
		if (membership[point_id] != index) {
			deltas[get_local_id(0)] = 1;
		}
#endif
		/* assign the membership to object point_id */
		membership[point_id] = index;
	}

#ifdef GPU_DELTA_REDUCTION
	// make sure all the deltas have finished writing to shared memory
	barrier(CLK_LOCAL_MEM_FENCE);

	// now let's count them
	// primitve reduction follows
	unsigned int threadids_participating = THREADS_PER_BLOCK / 2;
	for(;threadids_participating > 1; threadids_participating /= 2) {
		if(get_local_id(0) < threadids_participating) {
			deltas[get_local_id(0)] += deltas[get_local_id(0) + threadids_participating];
		}
		barrier(CLK_LOCAL_MEM_FENCE);
	}
	if(get_local_id(0) < 1)	{deltas[get_local_id(0)] += deltas[get_local_id(0) + 1];}
	barrier(CLK_LOCAL_MEM_FENCE);
	// propagate number of changes to global counter
	if(get_local_id(0) == 0) {
		block_deltas[get_group_id(1) * get_num_groups(0) + get_group_id(0)] = deltas[0];
		//printf("original id: %d, modified: %d\n", get_group_id(1)*get_num_groups(0)+get_group_id(0), get_group_id(0));

	}

#endif


#ifdef GPU_NEW_CENTER_REDUCTION
	int center_id = get_local_id(0) / nfeatures;    
	int dim_id = get_local_id(0) - nfeatures*center_id;

	__local int new_center_ids[THREADS_PER_BLOCK];

	new_center_ids[get_local_id(0)] = index;
	barrier(CLK_LOCAL_MEM_FENCE);

	/***
	  determine which dimension calculte the sum for
	  mapping of threads is
	  center0[dim0,dim1,dim2,...]center1[dim0,dim1,dim2,...]...
	 ***/ 	

	int new_base_index = (point_id - get_local_id(0))*nfeatures + dim_id;
	float accumulator = 0.f;

	if(get_local_id(0) < nfeatures * nclusters) {
		// accumulate over all the elements of this threadblock 
		for(int i = 0; i< (THREADS_PER_BLOCK); i++) {
			float val = features_flipped[new_base_index+i*nfeatures];
			if(new_center_ids[i] == center_id) 
				accumulator += val;
		}

		// now store the sum for this threadblock
		/***
		  mapping to global array is
		  block0[center0[dim0,dim1,dim2,...]center1[dim0,dim1,dim2,...]...]block1[...]...
		 ***/
		block_clusters[(get_group_id(1)*get_num_groups(0) + get_group_id(0)) * nclusters * nfeatures + get_local_id(0)] = accumulator;
	}
#endif

}
#endif // #ifndef _KMEANS_CUDA_KERNEL_H_
