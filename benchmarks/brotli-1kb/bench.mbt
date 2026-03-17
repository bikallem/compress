///|
fn compress_setup(size : Int) -> Bytes raise {
  @br.compress(@benchmarks.gen_text(size))
}

///|
fn bench_compress(
  b : @bench.T,
  name~ : String,
  size : Int,
  level? : @br.CompressionLevel = @br.DefaultCompression,
) -> Unit {
  let data = @benchmarks.gen_text(size)
  b.bench(name~, fn() { b.keep(try! @br.compress(data, level~)) })
}

///|
fn bench_decompress(b : @bench.T, name~ : String, size : Int) -> Unit raise {
  let compressed = compress_setup(size)
  b.bench(name~, fn() { b.keep(try! @br.decompress(compressed)) })
}

///|
test "bench brotli compress default text_1kb" (b : @bench.T) {
  bench_compress(b, name="brotli_compress_default_1kb", 1024)
}

///|
test "bench brotli decompress text_1kb" (b : @bench.T) {
  bench_decompress(b, name="brotli_decompress_1kb", 1024)
}
