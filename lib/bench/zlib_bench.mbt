///|
test "bench zlib compress default text_10kb" (b : @bench.T) {
  let data = gen_text(10240)
  b.bench(name="zlib_compress_default_10kb", fn() {
    b.keep(try! @zlib.compress(data))
  })
}

///|
test "bench zlib decompress text_10kb" (b : @bench.T) {
  let data = gen_text(10240)
  let compressed = @zlib.compress(data)
  b.bench(name="zlib_decompress_10kb", fn() {
    b.keep(try! @zlib.decompress(compressed))
  })
}
