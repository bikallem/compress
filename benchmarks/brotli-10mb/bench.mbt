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
fn bench_decompress(b : @bench.T, name~ : String, size : Int) -> Unit raise {
  let compressed = compress_setup(size)
  b.bench(name~, fn() { b.keep(try! @br.decompress(compressed)) })
}

///|
test "bench brotli compress default text_10mb" (b : @bench.T) {
  bench_compress(b, name="brotli_compress_default_10mb", 10485760)
}

///|
test "bench brotli decompress text_10mb" (b : @bench.T) {
  bench_decompress(b, name="brotli_decompress_10mb", 10485760)
}
