///|
fn compress_setup(size : Int) -> Bytes raise {
  @lw.compress(@benchmarks.gen_text(size), @lw.LSB, 8)
}

///|
fn bench_compress(b : @bench.T, name~ : String, size : Int) -> Unit {
  let data = @benchmarks.gen_text(size)
  b.bench(name~, fn() { b.keep(try! @lw.compress(data, @lw.LSB, 8)) })
}

///|
fn bench_decompress(b : @bench.T, name~ : String, size : Int) -> Unit raise {
  let compressed = compress_setup(size)
  b.bench(name~, fn() { b.keep(try! @lw.decompress(compressed, @lw.LSB, 8)) })
}

///|
test "bench lzw compress LSB text_500mb" (b : @bench.T) {
  bench_compress(b, name="lzw_compress_lsb_500mb", 524288000)
}

///|
test "bench lzw decompress LSB text_500mb" (b : @bench.T) {
  bench_decompress(b, name="lzw_decompress_lsb_500mb", 524288000)
}
