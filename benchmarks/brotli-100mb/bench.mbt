///|
fn compress_setup(size : Int) -> Bytes {
  @br.compress(@benchmarks.gen_text(size))
}

///|
fn bench_compress(b : @bench.T, name~ : String, size : Int) -> Unit {
  let data = @benchmarks.gen_text(size)
  b.bench(name~, fn() { b.keep(@br.compress(data)) })
}

///|
fn bench_decompress(b : @bench.T, name~ : String, size : Int) -> Unit {
  let compressed = compress_setup(size)
  b.bench(name~, fn() { b.keep(try! @br.decompress(compressed)) })
}

///|
test "bench brotli compress default text_100mb" (b : @bench.T) {
  bench_compress(b, name="brotli_compress_default_100mb", 104857600)
}

///|
test "bench brotli decompress text_100mb" (b : @bench.T) {
  bench_decompress(b, name="brotli_decompress_100mb", 104857600)
}
