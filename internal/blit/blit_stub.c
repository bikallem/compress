#include <string.h>
#include "moonbit.h"

#ifdef _MSC_VER
#include <intrin.h>
static __inline int ctzll_msvc(uint64_t val) {
  unsigned long idx;
#ifdef _WIN64
  _BitScanForward64(&idx, val);
#else
  if ((uint32_t)val != 0) {
    _BitScanForward(&idx, (uint32_t)val);
  } else {
    _BitScanForward(&idx, (uint32_t)(val >> 32));
    idx += 32;
  }
#endif
  return (int)idx;
}
#define CTZ64(x) ctzll_msvc(x)
#else
#define CTZ64(x) __builtin_ctzll(x)
#endif

// Fast byte array blit using memmove (vectorized by libc).
// FixedArray[Byte] has the same layout as Bytes (moonbit_bytes_t).
MOONBIT_FFI_EXPORT void bikallem_compress_internal_blit_blit_fixed_array(
    moonbit_bytes_t dst, int32_t dst_off,
    moonbit_bytes_t src, int32_t src_off,
    int32_t len) {
  memmove(dst + dst_off, src + src_off, (size_t)len);
}

// Fill a byte array region with a single byte value (vectorized memset).
MOONBIT_FFI_EXPORT void bikallem_compress_internal_blit_fill_bytes(
    moonbit_bytes_t dst, int32_t dst_off,
    uint8_t val, int32_t len) {
  memset(dst + dst_off, val, (size_t)len);
}

// Word-at-a-time match length comparison.
// Returns number of matching bytes between a[a_off..] and b[b_off..], up to max_len.
MOONBIT_FFI_EXPORT int32_t bikallem_compress_internal_blit_match_length(
    moonbit_bytes_t a, int32_t a_off,
    moonbit_bytes_t b, int32_t b_off,
    int32_t max_len) {
  const uint8_t *pa = a + a_off;
  const uint8_t *pb = b + b_off;
  int32_t i = 0;
  // Compare 8 bytes at a time
  while (i + 8 <= max_len) {
    uint64_t va, vb;
    memcpy(&va, pa + i, 8);
    memcpy(&vb, pb + i, 8);
    uint64_t diff = va ^ vb;
    if (diff != 0) {
      // Find first differing byte
      return i + CTZ64(diff) / 8;
    }
    i += 8;
  }
  // Handle remaining bytes
  while (i < max_len && pa[i] == pb[i]) {
    i++;
  }
  return i;
}

// Allocate a FixedArray[Byte] without zeroing.
// Uses moonbit_make_bytes_raw which skips memset.
MOONBIT_EXPORT moonbit_bytes_t moonbit_make_bytes_raw(int32_t len);

MOONBIT_FFI_EXPORT moonbit_bytes_t bikallem_compress_internal_blit_make_uninit(
    int32_t len) {
  return moonbit_make_bytes_raw(len);
}

// Allocate a FixedArray[Int] (int64) without zeroing.
MOONBIT_EXPORT int64_t *moonbit_make_int64_array_raw(int32_t len);

MOONBIT_FFI_EXPORT int64_t *bikallem_compress_internal_blit_make_uninit_int(
    int32_t len) {
  return moonbit_make_int64_array_raw(len);
}
