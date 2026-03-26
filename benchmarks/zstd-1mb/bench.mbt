///|
fn compress_setup(size : Int) -> Bytes {
  try! @zs.compress(@benchmarks.gen_text(size))
}

///|
fn bench_compress(b : @bench.T, name~ : String, size : Int) -> Unit {
  let data = @benchmarks.gen_text(size)
  b.bench(name~, fn() { b.keep(try! @zs.compress(data)) })
}

///|
fn bench_decompress(b : @bench.T, name~ : String, size : Int) -> Unit {
  let compressed = compress_setup(size)
  b.bench(name~, fn() { b.keep(try! @zs.decompress(compressed)) })
}

///|
test "bench zstd compress default text_1mb" (b : @bench.T) {
  bench_compress(b, name="zstd_compress_default_1mb", 1048576)
}

///|
test "bench zstd decompress text_1mb" (b : @bench.T) {
  bench_decompress(b, name="zstd_decompress_1mb", 1048576)
}
