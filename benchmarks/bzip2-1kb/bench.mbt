///|
fn compress_setup(size : Int) -> Bytes raise {
  @bz2.compress(@benchmarks.gen_text(size))
}

///|
fn bench_compress(b : @bench.T, name~ : String, size : Int) -> Unit {
  let data = @benchmarks.gen_text(size)
  b.bench(name~, fn() { b.keep(try! @bz2.compress(data)) })
}

///|
fn bench_decompress(b : @bench.T, name~ : String, size : Int) -> Unit raise {
  let compressed = compress_setup(size)
  b.bench(name~, fn() { b.keep(try! @bz2.decompress(compressed)) })
}

///|
test "bench bzip2 compress default text_1kb" (b : @bench.T) {
  bench_compress(b, name="bzip2_compress_default_1kb", 1024)
}

///|
test "bench bzip2 decompress text_1kb" (b : @bench.T) {
  bench_decompress(b, name="bzip2_decompress_1kb", 1024)
}
