///|
fn compress_setup(size : Int) -> Bytes {
  @l4.compress(@benchmarks.gen_text(size))
}

///|
fn bench_compress(b : @bench.T, name~ : String, size : Int) -> Unit {
  let data = @benchmarks.gen_text(size)
  b.bench(name~, fn() { b.keep(@l4.compress(data)) })
}

///|
fn bench_decompress(b : @bench.T, name~ : String, size : Int) -> Unit raise {
  let compressed = compress_setup(size)
  b.bench(name~, fn() { b.keep(try! @l4.decompress(compressed)) })
}

///|
test "bench lz4 compress text_1kb" (b : @bench.T) {
  bench_compress(b, name="lz4_compress_1kb", 1024)
}

///|
test "bench lz4 decompress text_1kb" (b : @bench.T) {
  bench_decompress(b, name="lz4_decompress_1kb", 1024)
}
