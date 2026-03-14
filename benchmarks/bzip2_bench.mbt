///|
test "bench bzip2 compress default text_1kb" (b : @bench.T) {
  bench_bzip2_compress(b, name="bzip2_compress_default_1kb", 1024)
}

///|
test "bench bzip2 compress default text_10kb" (b : @bench.T) {
  bench_bzip2_compress(b, name="bzip2_compress_default_10kb", 10240)
}

///|
test "bench bzip2 compress default text_100kb" (b : @bench.T) {
  bench_bzip2_compress(b, name="bzip2_compress_default_100kb", 102400)
}

///|
test "bench bzip2 decompress text_1kb" (b : @bench.T) {
  bench_bzip2_decompress(b, name="bzip2_decompress_1kb", 1024)
}

///|
test "bench bzip2 decompress text_10kb" (b : @bench.T) {
  bench_bzip2_decompress(b, name="bzip2_decompress_10kb", 10240)
}

///|
test "bench bzip2 decompress text_100kb" (b : @bench.T) {
  bench_bzip2_decompress(b, name="bzip2_decompress_100kb", 102400)
}

///|
test "bench bzip2 decompress text_1mb" (b : @bench.T) {
  bench_bzip2_decompress(b, name="bzip2_decompress_1mb", 1048576)
}
