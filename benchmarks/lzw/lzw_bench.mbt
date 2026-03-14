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
test "bench lzw compress LSB text_1kb" (b : @bench.T) {
  bench_compress(b, name="lzw_compress_lsb_1kb", 1024)
}

///|
test "bench lzw compress LSB text_10kb" (b : @bench.T) {
  bench_compress(b, name="lzw_compress_lsb_10kb", 10240)
}

///|
test "bench lzw decompress LSB text_1kb" (b : @bench.T) {
  bench_decompress(b, name="lzw_decompress_lsb_1kb", 1024)
}

///|
test "bench lzw decompress LSB text_10kb" (b : @bench.T) {
  bench_decompress(b, name="lzw_decompress_lsb_10kb", 10240)
}

///|
test "bench lzw decompress LSB text_100kb" (b : @bench.T) {
  bench_decompress(b, name="lzw_decompress_lsb_100kb", 102400)
}

///|
test "bench lzw decompress LSB text_1mb" (b : @bench.T) {
  bench_decompress(b, name="lzw_decompress_lsb_1mb", 1048576)
}

///|
test "bench lzw decompress LSB text_10mb" (b : @bench.T) {
  bench_decompress(b, name="lzw_decompress_lsb_10mb", 10485760)
}

///|
test "bench lzw decompress LSB text_100mb" (b : @bench.T) {
  bench_decompress(b, name="lzw_decompress_lsb_100mb", 104857600)
}

///|
test "bench lzw compress LSB text_100kb" (b : @bench.T) {
  bench_compress(b, name="lzw_compress_lsb_100kb", 102400)
}

///|
test "bench lzw compress LSB text_1mb" (b : @bench.T) {
  bench_compress(b, name="lzw_compress_lsb_1mb", 1048576)
}

///|
test "bench lzw compress LSB text_10mb" (b : @bench.T) {
  bench_compress(b, name="lzw_compress_lsb_10mb", 10485760)
}
