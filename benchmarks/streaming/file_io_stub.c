#include <stdio.h>
#include <stdlib.h>
#include "moonbit.h"

MOONBIT_FFI_EXPORT int64_t bench_fopen_read(moonbit_bytes_t path) {
  FILE *f = fopen((const char *)path, "rb");
  return (int64_t)(uintptr_t)f;
}

MOONBIT_FFI_EXPORT int64_t bench_fopen_write(moonbit_bytes_t path) {
  FILE *f = fopen((const char *)path, "wb");
  return (int64_t)(uintptr_t)f;
}

MOONBIT_FFI_EXPORT int32_t bench_fread_bytes(int64_t handle, moonbit_bytes_t buf, int32_t offset, int32_t max_len) {
  FILE *f = (FILE *)(uintptr_t)handle;
  return (int32_t)fread(buf + offset, 1, max_len, f);
}

MOONBIT_FFI_EXPORT void bench_fwrite(int64_t handle, moonbit_bytes_t data, int32_t len) {
  FILE *f = (FILE *)(uintptr_t)handle;
  fwrite(data, 1, len, f);
}

MOONBIT_FFI_EXPORT void bench_fclose(int64_t handle) {
  FILE *f = (FILE *)(uintptr_t)handle;
  if (f) fclose(f);
}

MOONBIT_FFI_EXPORT void bench_remove(moonbit_bytes_t path) {
  remove((const char *)path);
}
