#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "moonbit.h"

// File I/O for benchmarking (native target only).
// Path arguments are null-terminated Bytes from MoonBit.

MOONBIT_FFI_EXPORT int64_t bench_fopen_read(moonbit_bytes_t path) {
  FILE *f = fopen((const char *)path, "rb");
  return (int64_t)(uintptr_t)f;
}

MOONBIT_FFI_EXPORT int64_t bench_fopen_write(moonbit_bytes_t path) {
  FILE *f = fopen((const char *)path, "wb");
  return (int64_t)(uintptr_t)f;
}

// Read into a FixedArray[Byte] (same layout as moonbit_bytes_t).
MOONBIT_FFI_EXPORT int32_t bench_fread(int64_t handle, moonbit_bytes_t buf, int32_t max_len) {
  FILE *f = (FILE *)(uintptr_t)handle;
  return (int32_t)fread(buf, 1, max_len, f);
}

// Write from a Bytes.
MOONBIT_FFI_EXPORT void bench_fwrite(int64_t handle, moonbit_bytes_t data, int32_t len) {
  FILE *f = (FILE *)(uintptr_t)handle;
  fwrite(data, 1, len, f);
}

MOONBIT_FFI_EXPORT void bench_fclose(int64_t handle) {
  FILE *f = (FILE *)(uintptr_t)handle;
  if (f) fclose(f);
}

MOONBIT_FFI_EXPORT int64_t bench_file_size(int64_t handle) {
  FILE *f = (FILE *)(uintptr_t)handle;
  long cur = ftell(f);
  fseek(f, 0, SEEK_END);
  long size = ftell(f);
  fseek(f, cur, SEEK_SET);
  return (int64_t)size;
}

MOONBIT_FFI_EXPORT int64_t bench_clock_ns(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (int64_t)ts.tv_sec * 1000000000LL + (int64_t)ts.tv_nsec;
}

// Get RSS from /proc/self/statm (Linux only)
MOONBIT_FFI_EXPORT int64_t bench_rss_bytes(void) {
  FILE *f = fopen("/proc/self/statm", "r");
  if (!f) return 0;
  long pages, rss;
  if (fscanf(f, "%ld %ld", &pages, &rss) != 2) {
    fclose(f);
    return 0;
  }
  fclose(f);
  return (int64_t)rss * 4096;
}
