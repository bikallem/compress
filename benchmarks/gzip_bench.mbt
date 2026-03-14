///|
test "bench gzip compress default text_1kb" (b : @bench.T) {
  bench_gzip_compress(b, name="gzip_compress_default_1kb", 1024)
}

///|
test "bench gzip compress default text_10kb" (b : @bench.T) {
  bench_gzip_compress(b, name="gzip_compress_default_10kb", 10240)
}

///|
test "bench gzip decompress text_1kb" (b : @bench.T) {
  bench_gzip_decompress(b, name="gzip_decompress_1kb", 1024)
}

///|
test "bench gzip decompress text_10kb" (b : @bench.T) {
  bench_gzip_decompress(b, name="gzip_decompress_10kb", 10240)
}

///|
test "bench gzip compress best_speed text_10kb" (b : @bench.T) {
  bench_gzip_compress(
    b,
    name="gzip_compress_speed_10kb",
    10240,
    level=BestSpeed,
  )
}

///|
test "bench gzip decompress text_100kb" (b : @bench.T) {
  bench_gzip_decompress(b, name="gzip_decompress_100kb", 102400)
}

///|
test "bench gzip decompress text_1mb" (b : @bench.T) {
  bench_gzip_decompress(b, name="gzip_decompress_1mb", 1048576)
}

///|
test "bench gzip decompress text_10mb" (b : @bench.T) {
  bench_gzip_decompress(b, name="gzip_decompress_10mb", 10485760)
}

///|
test "bench gzip decompress text_100mb" (b : @bench.T) {
  bench_gzip_decompress(b, name="gzip_decompress_100mb", 104857600)
}

///|
test "bench gzip decompress text_500mb" (b : @bench.T) {
  bench_gzip_decompress(b, name="gzip_decompress_500mb", 524288000)
}

///|
test "bench gzip decompress text_1gb" (b : @bench.T) {
  bench_gzip_decompress(b, name="gzip_decompress_1gb", 1073741824)
}

///|
test "bench gzip compress default text_500mb" (b : @bench.T) {
  bench_gzip_compress(b, name="gzip_compress_default_500mb", 524288000)
}

///|
test "bench gzip compress default text_100kb" (b : @bench.T) {
  bench_gzip_compress(b, name="gzip_compress_default_100kb", 102400)
}

///|
test "bench gzip compress default text_1mb" (b : @bench.T) {
  bench_gzip_compress(b, name="gzip_compress_default_1mb", 1048576)
}

///|
test "bench gzip compress default text_10mb" (b : @bench.T) {
  bench_gzip_compress(b, name="gzip_compress_default_10mb", 10485760)
}

///|
test "bench gzip compress default text_100mb" (b : @bench.T) {
  bench_gzip_compress(b, name="gzip_compress_default_100mb", 104857600)
}
