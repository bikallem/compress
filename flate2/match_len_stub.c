#include <string.h>
#include <stdint.h>
#include "moonbit.h"

#ifdef _MSC_VER
#include <intrin.h>
static inline int ctzll(uint64_t v) {
  unsigned long idx;
  _BitScanForward64(&idx, v);
  return (int)idx;
}
#else
#define ctzll(v) __builtin_ctzll(v)
#endif

MOONBIT_FFI_EXPORT int32_t bikallem_compress_flate2_match_len(
    moonbit_bytes_t data, int32_t a, int32_t b, int32_t max_len) {
  const uint8_t *pa = data + a;
  const uint8_t *pb = data + b;
  int32_t n = 0;
  while (n + 8 <= max_len) {
    uint64_t va, vb;
    memcpy(&va, pa + n, 8);
    memcpy(&vb, pb + n, 8);
    uint64_t diff = va ^ vb;
    if (diff != 0) {
      return n + ctzll(diff) / 8;
    }
    n += 8;
  }
  while (n < max_len && pa[n] == pb[n]) {
    n++;
  }
  return n;
}
