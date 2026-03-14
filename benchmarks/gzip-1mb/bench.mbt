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
test "bench gzip compress default text_1mb" (b : @bench.T) {
  bench_compress(b, name="gzip_compress_default_1mb", 1048576)
}

///|
test "bench gzip decompress text_1mb" (b : @bench.T) {
  bench_decompress(b, name="gzip_decompress_1mb", 1048576)
}
