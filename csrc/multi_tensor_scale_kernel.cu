#include <ATen/ATen.h>
#include <ATen/AccumulateType.h>
#include <ATen/cuda/CUDAContext.h>
#include <ATen/cuda/Exceptions.h>
#include "multi_tensor_apply.cuh"

#include <assert.h>
#include <cuda_runtime.h>

#define BLOCK_SIZE 512
#define ILP 4

template<typename in_t, typename out_t>
struct ScaleFunctor
{
   __device__ __forceinline__ void operator()(
    int chunk_size,
    volatile int* noop_gmem,
    TensorList<2>& tl,
    float scale)
  {
    __shared__ int noop_smem;

    if(threadIdx.x == 0)
      noop_smem = *noop_gmem;
    __syncthreads();
    if(noop_smem == 1)
      return;

    int tensor_loc = tl.block_to_tensor[blockIdx.x];
    int chunk_idx = tl.block_to_chunk[blockIdx.x];
    int n = tl.sizes[tensor_loc];

    in_t* in = (in_t*)tl.addresses[0][tensor_loc];
    in += chunk_idx*chunk_size;
   
    out_t* out = (out_t*)tl.addresses[1][tensor_loc];
    out += chunk_idx*chunk_size;

    n -= chunk_idx*chunk_size;

    // Non-divergent exit condition for the __syncthreads
    float incoming_vals[ILP];
    for(int i_start = 0;
        i_start < n && i_start < chunk_size;
        i_start += blockDim.x*ILP)
    {
      #pragma unroll
      for(int ii = 0; ii < ILP; ii++)
      {
        incoming_vals[ii] = 0;
        int i = i_start + threadIdx.x + ii*blockDim.x;
        if(i < n && i < chunk_size)
          incoming_vals[ii] = static_cast<float>(in[i]);
      }

      // note for clarification to future michael:
      // From a pure memory dependency perspective, there's likely no point unrolling
      // the write loop, since writes just fire off once their LDGs arrive.
      // Put another way, the STGs are dependent on the LDGs, but not on each other.
      // There is still compute ILP benefit from unrolling the loop though.
      #pragma unroll
      for(int ii = 0; ii < ILP; ii++)
      {
        int i = i_start + threadIdx.x + ii*blockDim.x;
        if(i < n && i < chunk_size)
          if(isfinite(incoming_vals[ii]))
            out[i] = static_cast<out_t>(incoming_vals[ii]*scale);
          else
            *noop_gmem = 1; // Blindly fire off a write.  These will race but that's ok.
      }

      // *noop_gmem = 1 is NOT guaranteed to be seen immediately by thread 0.  I wonder if
      // we can rig block-wide and grid-wide short-circuiting with only one syncthreads.
      // It's possible we can just lean on the cache (no smem or syncs) and still be fast.
      if(threadIdx.x == 0)
        noop_smem = *noop_gmem;
      __syncthreads();
      if(noop_smem == 1)
        break;
    }
  }
};

void multi_tensor_scale_cuda(
  int chunk_size,
  at::Tensor noop_flag,
  std::vector<std::vector<at::Tensor>> tensor_lists,
  float scale)
{
  // The output (downscaled) type is always float.
  // If build times suffer, think about where to put this dispatch,
  // and what logic should be moved out of multi_tensor_apply.
  AT_DISPATCH_FLOATING_TYPES_AND_HALF(tensor_lists[0][0].type(),
     "multi_tensor_scale_cuda",
     [&]
     {
       // using accscalar_t = acc_type<scalar_t, true>;
       switch(tensor_lists[1][0].type().scalarType())
       {
         case at::ScalarType::Half:
           multi_tensor_apply<2>(
             BLOCK_SIZE,
             chunk_size,
             noop_flag,
             tensor_lists,
             ScaleFunctor<scalar_t, at::Half>(),
             scale);
           break;
         case at::ScalarType::Float:
           multi_tensor_apply<2>(
             BLOCK_SIZE,
             chunk_size,
             noop_flag,
             tensor_lists,
             ScaleFunctor<scalar_t, float>(),
             scale);
           break;
         default:
           AT_ERROR("multi_tensor_scale_cuda not implemented for output type = ",
                    tensor_lists[1][0].type().toString());
       }
     });

  AT_CUDA_CHECK(cudaGetLastError());

  // AT_CUDA_CHECK(cudaDeviceSynchronize());
}
