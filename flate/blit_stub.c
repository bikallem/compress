#include <string.h>
#include "moonbit.h"

// Fast byte array blit using memmove (vectorized by libc).
// FixedArray[Byte] has the same layout as Bytes (moonbit_bytes_t).
MOONBIT_FFI_EXPORT void bikallem_compress_flate_blit_bytes(
    moonbit_bytes_t dst, int32_t dst_off,
    moonbit_bytes_t src, int32_t src_off,
    int32_t len) {
  memmove(dst + dst_off, src + src_off, (size_t)len);
}

// Fill a byte array region with a single byte value (vectorized memset).
MOONBIT_FFI_EXPORT void bikallem_compress_flate_fill_bytes(
    moonbit_bytes_t dst, int32_t dst_off,
    int32_t val, int32_t len) {
  memset(dst + dst_off, val, (size_t)len);
}
