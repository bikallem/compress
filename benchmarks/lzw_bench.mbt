///|
test "bench lzw compress LSB text_1kb" (b : @bench.T) {
  bench_lzw_compress(b, name="lzw_compress_lsb_1kb", 1024)
}

///|
test "bench lzw compress LSB text_10kb" (b : @bench.T) {
  bench_lzw_compress(b, name="lzw_compress_lsb_10kb", 10240)
}

///|
test "bench lzw decompress LSB text_1kb" (b : @bench.T) {
  bench_lzw_decompress(b, name="lzw_decompress_lsb_1kb", 1024)
}

///|
test "bench lzw decompress LSB text_10kb" (b : @bench.T) {
  bench_lzw_decompress(b, name="lzw_decompress_lsb_10kb", 10240)
}

///|
test "bench lzw decompress LSB text_100kb" (b : @bench.T) {
  bench_lzw_decompress(b, name="lzw_decompress_lsb_100kb", 102400)
}

///|
test "bench lzw decompress LSB text_1mb" (b : @bench.T) {
  bench_lzw_decompress(b, name="lzw_decompress_lsb_1mb", 1048576)
}

///|
test "bench lzw decompress LSB text_10mb" (b : @bench.T) {
  bench_lzw_decompress(b, name="lzw_decompress_lsb_10mb", 10485760)
}

///|
test "bench lzw decompress LSB text_100mb" (b : @bench.T) {
  bench_lzw_decompress(b, name="lzw_decompress_lsb_100mb", 104857600)
}

///|
test "bench lzw decompress LSB text_500mb" (b : @bench.T) {
  bench_lzw_decompress(b, name="lzw_decompress_lsb_500mb", 524288000)
}

///|
test "bench lzw compress LSB text_100kb" (b : @bench.T) {
  bench_lzw_compress(b, name="lzw_compress_lsb_100kb", 102400)
}

///|
test "bench lzw compress LSB text_1mb" (b : @bench.T) {
  bench_lzw_compress(b, name="lzw_compress_lsb_1mb", 1048576)
}

///|
test "bench lzw compress LSB text_10mb" (b : @bench.T) {
  bench_lzw_compress(b, name="lzw_compress_lsb_10mb", 10485760)
}

///|
test "bench lzw compress LSB text_100mb" (b : @bench.T) {
  bench_lzw_compress(b, name="lzw_compress_lsb_100mb", 104857600)
}
