///|
fn compress_setup(size : Int) -> Bytes {
  @snap.compress(@benchmarks.gen_text(size))
}

///|
fn bench_compress(b : @bench.T, name~ : String, size : Int) -> Unit {
  let data = @benchmarks.gen_text(size)
  b.bench(name~, fn() { b.keep(@snap.compress(data)) })
}

///|
fn bench_decompress(b : @bench.T, name~ : String, size : Int) -> Unit {
  let compressed = compress_setup(size)
  b.bench(name~, fn() { b.keep(try! @snap.decompress(compressed)) })
}

///|
test "bench snappy compress text_1mb" (b : @bench.T) {
  bench_compress(b, name="snappy_compress_1mb", 1048576)
}

///|
test "bench snappy decompress text_1mb" (b : @bench.T) {
  bench_decompress(b, name="snappy_decompress_1mb", 1048576)
}
