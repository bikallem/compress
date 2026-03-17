///|
fn compress_setup(size : Int) -> Bytes {
  @zs.compress(@benchmarks.gen_text(size))
}

///|
fn bench_compress(b : @bench.T, name~ : String, size : Int) -> Unit {
  let data = @benchmarks.gen_text(size)
  b.bench(name~, fn() { b.keep(@zs.compress(data)) })
}

///|
fn bench_decompress(b : @bench.T, name~ : String, size : Int) -> Unit raise {
  let compressed = compress_setup(size)
  b.bench(name~, fn() { b.keep(try! @zs.decompress(compressed)) })
}

///|
test "bench zstd compress default text_10kb" (b : @bench.T) {
  bench_compress(b, name="zstd_compress_default_10kb", 10240)
}

///|
test "bench zstd decompress text_10kb" (b : @bench.T) {
  bench_decompress(b, name="zstd_decompress_10kb", 10240)
}
