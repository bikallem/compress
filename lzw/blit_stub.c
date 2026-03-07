#include <string.h>
#include "moonbit.h"

// Fast byte array blit using memmove (vectorized by libc).
// FixedArray[Byte] has the same layout as Bytes (moonbit_bytes_t).
MOONBIT_FFI_EXPORT void bikallem_compress_lzw_blit_bytes(
    moonbit_bytes_t dst, int32_t dst_off,
    moonbit_bytes_t src, int32_t src_off,
    int32_t len) {
  if (len > 0) {
    memmove(dst + dst_off, src + src_off, (size_t)len);
  }
}
