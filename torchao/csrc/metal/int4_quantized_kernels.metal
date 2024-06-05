#include <metal_simdgroup>
#include <metal_stdlib>
using namespace metal;

template <typename T> struct Vec4Type {};

template <> struct Vec4Type<float> { using type = float4; };

template <> struct Vec4Type<half> { using type = half4; };

#if __METAL_VERSION__ >= 310
template <> struct Vec4Type<bfloat> { using type = bfloat4; };
#endif

/*
   This code takes heavy inspiration from MLX qmv kernel here:
   https://github.com/ml-explore/mlx/blob/main/mlx/backend/metal/kernels/quantized.metal#L381
   Specifically:
     - Multiplying activation by inverse scaling factor to reduce compute
   boundedness
     - Handling zero point by accumulating act in separate sum term. Needed with
   optimization done above. MLX MIT License:
   https://github.com/ml-explore/mlx/blob/main/LICENSE
*/

/*
   A matrix is [M x K] (right now this kernel does not support M > 1 but this is
   a very easy fix that will follow right after) B matrix is [N x K]. For 4 bit
   2 of the k values are packed in one byte so you can think of B as [N x K/2]
   matrix from layout perspective.

   Since this kernel is optimizing for gemv case, we split work, along reduction
   dim k, among the threads of same simdgroup. Ex: if K = 4096 and simdgroup
   size is 32 (current algorithm should work as long as simdgroup size is > 32).
   Then each thread will accumulate 4096/32 = 128 k values. However these 128
   values, handled by each thread are not laid out contiguously. Each thread
   handles 4 contiguous k values and then jumps 128 elements, k_jump =
   thread_per_channel (32) * ks_per_thread (4). Take a simpler example where
   simdgroup is of size 4. In this case threads_per_channel = 4. Assume K = 32
   K =        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18,
   19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31] thread      ---- 0 ---
   ---- 1 ---  ---- 2 -----  ----- 3 ------  ------ 0 -----  ------ 1 -----
   ----- 2 ------- ---- 3 ------- id in simd group that handle corresponding
   k
   Thread 0 here is handling (0, 1, 2, 3) and then (16, 17, 18, 19). They are
   apare by k_jump = 4 * 4 = 16 This is done improve memory access locality
   amonng threads that are working co-operatively. Once each thread has their
   partial sums accumulated, we use tree reduction (Metal offers simd_sum but
   not used because this code would also work with simdgroup size = 64). In the
   example above we will have 4 partial sums.

   Each thread also handles 4 different output rows. Thus each simdgroup will be
   responsible for (1x4) tile of the output. We havent evaluated whether a
   different tile size is better or not. We probably will do some auto-tuning
   once initial work is done.
*/

/*
   @brief This shader implements 4-bit matrix-vector multiplication where A
   matrix is fp16, bfloat or float and B matrix is a 4-bit quantized weight
   matrix. B matrix is quantized, with group wise quantization. As of now this
   code is tested for group size = 32.
   @param [in] A is activation matrix of size M x K.
   @param [in] B is weight matrix of size M x K. Each byte contains 2 4bit
   values, along K dim, packed together.
   @param [in] scalesAndZeros is scales and zero points corresponding each
   output channel x groups. These are packed as [N, groupSize, 2]. N = output
   channels. Last 2 correspond to packing scale and zero point together.
   @param [out] outputData is output matrix of size M x N.
   @param [in] sizes array contains values of M, N and K.
   @param [in] thread_index is global thread id.
   @param [in] tid_in_simdgruop is thread id in simdgroup. e.g. in simdgroup of
   size 32 it can be in [0-31].
*/
/*
TODOs:
   Right now code handles only M = 1 case. Fix that.
*/
template <typename T, unsigned groupSize>
kernel void int4pack_mv(constant T *A [[buffer(0)]],
                        constant uchar *B [[buffer(1)]],
    constant T                 * scales_ptr     [[buffer(2)]],
    constant T                 * zeros_ptr      [[buffer(3)]],
    device   T                 * outputData     [[buffer(4)]],
    constant uint3             & sizes          [[buffer(5)]], // M, K, N
                        uint thread_index [[thread_position_in_grid]],
                        uint tid_in_simdgroup [[thread_index_in_simdgroup]]) {
  constexpr uint threads_per_channel = 32;
  constexpr uint ks_per_thread = 4;
  constexpr uint k_pack_factor = 2;
  const uint K = sizes.y;
  const uint N = sizes.z;
  uint n = thread_index; // 0..N/4-1
  n = n / threads_per_channel;
  n = n * 4;
  // This is starting k for each thread. In the example above, for thread 1 this
  // value will be 4.
  uint k = (tid_in_simdgroup % threads_per_channel) * ks_per_thread;
  constexpr int k_jump = threads_per_channel * ks_per_thread;

  using vecT = typename Vec4Type<T>::type;
  constant vecT *A_ptr = reinterpret_cast<constant vecT *>(A);
  constant uchar *B_ptr = B + ((n * K) / k_pack_factor);

  thread float4 rc = float4(0.0);
  float4 act_div_scales = {1.f, 1 / 16.f, 1 / 256.f, 1 / 4096.f};

  uint k_block_index = k / groupSize;
  uint sz_n_offset = (k_block_index * N + n);
  uint sz_jump = N * (k_jump / groupSize); /* accounts for identifying the group this thread will have to process in each iteration. This mean each iteration it must jump to a different group. Thus k_jump must be > grupSize */
  for (; k < K; k += k_jump) {
      vecT scales = (reinterpret_cast<constant vecT*>(scales_ptr + sz_n_offset))[0];
    // Adding zero point results in 10% perf penalty.
      vecT zeros = (reinterpret_cast<constant vecT*>(zeros_ptr + sz_n_offset))[0];
      zeros = zeros - scales * T(8);
      float4 zeros_float = float4(zeros);

      sz_n_offset += sz_jump;

    float4 a_val = float4(A_ptr[k / 4]);   // * k_scales;
    float4 a_vec = a_val * act_div_scales; // * k_scales;
    float a_val_sum = a_val[0] + a_val[1] + a_val[2] + a_val[3];

    float4x4 b_mat;
    ushort b_val0 = (reinterpret_cast<constant ushort *>(
        B_ptr + (k + 0 * K) / k_pack_factor))[0];
    ushort b_val1 = (reinterpret_cast<constant ushort *>(
        B_ptr + (k + 1 * K) / k_pack_factor))[0];
    ushort b_val2 = (reinterpret_cast<constant ushort *>(
        B_ptr + (k + 2 * K) / k_pack_factor))[0];
    ushort b_val3 = (reinterpret_cast<constant ushort *>(
        B_ptr + (k + 3 * K) / k_pack_factor))[0];
    b_mat[0] = scales[0] * float4(float(b_val0 & 0x000f), float(b_val0 & 0x00f0),
                               float(b_val0 & 0x0f00), float(b_val0 & 0xf000));
    b_mat[1] = scales[1] * float4(float(b_val1 & 0x000f), float(b_val1 & 0x00f0),
                               float(b_val1 & 0x0f00), float(b_val1 & 0xf000));
    b_mat[2] = scales[2] * float4(float(b_val2 & 0x000f), float(b_val2 & 0x00f0),
                               float(b_val2 & 0x0f00), float(b_val2 & 0xf000));
    b_mat[3] = scales[3] * float4(float(b_val3 & 0x000f), float(b_val3 & 0x00f0),
                               float(b_val3 & 0x0f00), float(b_val3 & 0xf000));

    rc += a_vec * b_mat;
    rc += a_val_sum * zeros_float;
  }
  rc += simd_shuffle_down(rc, 1);
  rc += simd_shuffle_down(rc, 2);
  rc += simd_shuffle_down(rc, 4);
  rc += simd_shuffle_down(rc, 8);
  rc += simd_shuffle_down(rc, 16);
  if (tid_in_simdgroup % threads_per_channel == 0) {
    reinterpret_cast<device vecT *>(outputData)[n / 4] = vecT(rc);
  }
}

#define INSTANTIATE_INT4MV(DTYPE, GSIZE)                                       \
  template [[host_name("int4pack_mv_" #GSIZE "_" #DTYPE)]] kernel void         \
  int4pack_mv<DTYPE, GSIZE>(                                                   \
      constant DTYPE * A [[buffer(0)]], constant uchar * B [[buffer(1)]],      \
    constant DTYPE             * scales_ptr     [[buffer(2)]],           \
    constant DTYPE             * zeros_ptr      [[buffer(3)]],           \
    device   DTYPE             * outputData     [[buffer(4)]],           \
    constant uint3             & sizes          [[buffer(5)]],           \
      uint thread_index [[thread_position_in_grid]],                           \
      uint tid_in_simdgroup [[thread_index_in_simdgroup]])

INSTANTIATE_INT4MV(float, 32);
INSTANTIATE_INT4MV(half, 32);
INSTANTIATE_INT4MV(float, 64);
INSTANTIATE_INT4MV(half, 64);
INSTANTIATE_INT4MV(float, 128);
INSTANTIATE_INT4MV(half, 128);
INSTANTIATE_INT4MV(float, 256);
INSTANTIATE_INT4MV(half, 256);
#if __METAL_VERSION__ >= 310
INSTANTIATE_INT4MV(bfloat, 32);
INSTANTIATE_INT4MV(bfloat, 64);
INSTANTIATE_INT4MV(bfloat, 128);
INSTANTIATE_INT4MV(bfloat, 256);
#endif