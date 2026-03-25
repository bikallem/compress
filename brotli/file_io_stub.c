#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "moonbit.h"

MOONBIT_FFI_EXPORT int64_t golden_fopen_write(moonbit_bytes_t path) {
  FILE *f = fopen((const char *)path, "wb");
  return (int64_t)(uintptr_t)f;
}

MOONBIT_FFI_EXPORT int64_t golden_fopen_read(moonbit_bytes_t path) {
  FILE *f = fopen((const char *)path, "rb");
  return (int64_t)(uintptr_t)f;
}

MOONBIT_FFI_EXPORT int32_t golden_fread(int64_t handle, moonbit_bytes_t buf, int32_t max_len) {
  FILE *f = (FILE *)(uintptr_t)handle;
  return (int32_t)fread(buf, 1, max_len, f);
}

MOONBIT_FFI_EXPORT void golden_fwrite(int64_t handle, moonbit_bytes_t data, int32_t len) {
  FILE *f = (FILE *)(uintptr_t)handle;
  fwrite(data, 1, len, f);
}

MOONBIT_FFI_EXPORT void golden_fclose(int64_t handle) {
  FILE *f = (FILE *)(uintptr_t)handle;
  if (f) fclose(f);
}

MOONBIT_FFI_EXPORT int64_t golden_file_size(int64_t handle) {
  FILE *f = (FILE *)(uintptr_t)handle;
  long cur = ftell(f);
  fseek(f, 0, SEEK_END);
  long size = ftell(f);
  fseek(f, cur, SEEK_SET);
  return (int64_t)size;
}
