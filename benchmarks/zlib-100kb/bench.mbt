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
test "bench zlib compress default text_100kb" (b : @bench.T) {
  bench_compress(b, name="zlib_compress_default_100kb", 102400)
}

///|
test "bench zlib decompress text_100kb" (b : @bench.T) {
  bench_decompress(b, name="zlib_decompress_100kb", 102400)
}
