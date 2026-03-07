///|
test "bench lzw compress LSB text_10kb" (b : @bench.T) {
  let data = gen_text(10240)
  b.bench(name="lzw_compress_lsb_10kb", fn() {
    b.keep(try! @lzw.compress(data, @lzw.LSB, 8))
  })
}

///|
test "bench lzw decompress LSB text_10kb" (b : @bench.T) {
  let data = gen_text(10240)
  let compressed = @lzw.compress(data, @lzw.LSB, 8)
  b.bench(name="lzw_decompress_lsb_10kb", fn() {
    b.keep(try! @lzw.decompress(compressed, @lzw.LSB, 8))
  })
}
