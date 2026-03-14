///|
fn compress_setup(size : Int) -> Bytes raise {
  @gz.compress(@benchmarks.gen_text(size))
}

///|
fn bench_compress(
  b : @bench.T,
  name~ : String,
  size : Int,
  level? : @flate.CompressionLevel = DefaultCompression,
) -> Unit {
  let data = @benchmarks.gen_text(size)
  b.bench(name~, fn() { b.keep(try! @gz.compress(data, level~)) })
}

///|
fn bench_decompress(b : @bench.T, name~ : String, size : Int) -> Unit raise {
  let compressed = compress_setup(size)
  b.bench(name~, fn() { b.keep(try! @gz.decompress(compressed)) })
}

///|
test "bench gzip compress default text_1kb" (b : @bench.T) {
  bench_compress(b, name="gzip_compress_default_1kb", 1024)
}

///|
test "bench gzip compress default text_10kb" (b : @bench.T) {
  bench_compress(b, name="gzip_compress_default_10kb", 10240)
}

///|
test "bench gzip decompress text_1kb" (b : @bench.T) {
  bench_decompress(b, name="gzip_decompress_1kb", 1024)
}

///|
test "bench gzip decompress text_10kb" (b : @bench.T) {
  bench_decompress(b, name="gzip_decompress_10kb", 10240)
}

///|
test "bench gzip compress best_speed text_10kb" (b : @bench.T) {
  bench_compress(b, name="gzip_compress_speed_10kb", 10240, level=BestSpeed)
}

///|
test "bench gzip decompress text_100kb" (b : @bench.T) {
  bench_decompress(b, name="gzip_decompress_100kb", 102400)
}

///|
test "bench gzip decompress text_1mb" (b : @bench.T) {
  bench_decompress(b, name="gzip_decompress_1mb", 1048576)
}

///|
test "bench gzip decompress text_10mb" (b : @bench.T) {
  bench_decompress(b, name="gzip_decompress_10mb", 10485760)
}

///|
test "bench gzip decompress text_100mb" (b : @bench.T) {
  bench_decompress(b, name="gzip_decompress_100mb", 104857600)
}

///|
test "bench gzip compress default text_100kb" (b : @bench.T) {
  bench_compress(b, name="gzip_compress_default_100kb", 102400)
}

///|
test "bench gzip compress default text_1mb" (b : @bench.T) {
  bench_compress(b, name="gzip_compress_default_1mb", 1048576)
}

///|
test "bench gzip compress default text_10mb" (b : @bench.T) {
  bench_compress(b, name="gzip_compress_default_10mb", 10485760)
}
