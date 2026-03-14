///|
fn compress_setup(size : Int) -> Bytes raise {
  @zl.compress(@benchmarks.gen_text(size))
}

///|
fn bench_compress(
  b : @bench.T,
  name~ : String,
  size : Int,
  level? : @flate.CompressionLevel = DefaultCompression,
) -> Unit {
  let data = @benchmarks.gen_text(size)
  b.bench(name~, fn() { b.keep(try! @zl.compress(data, level~)) })
}

///|
fn bench_decompress(b : @bench.T, name~ : String, size : Int) -> Unit raise {
  let compressed = compress_setup(size)
  b.bench(name~, fn() { b.keep(try! @zl.decompress(compressed)) })
}

///|
test "bench zlib compress default text_10kb" (b : @bench.T) {
  bench_compress(b, name="zlib_compress_default_10kb", 10240)
}

///|
test "bench zlib decompress text_10kb" (b : @bench.T) {
  bench_decompress(b, name="zlib_decompress_10kb", 10240)
}

///|
test "bench zlib compress best_speed text_10kb" (b : @bench.T) {
  bench_compress(b, name="zlib_compress_speed_10kb", 10240, level=BestSpeed)
}
