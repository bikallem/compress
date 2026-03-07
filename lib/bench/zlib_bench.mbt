///|
test "bench zlib compress default text_1kb" (b : @bench.T) {
  let data = gen_text(1024)
  b.bench(name="zlib_compress_default_1kb", fn() {
    b.keep(try! @zlib.compress(data))
  })
}

///|
test "bench zlib compress default text_10kb" (b : @bench.T) {
  let data = gen_text(10240)
  b.bench(name="zlib_compress_default_10kb", fn() {
    b.keep(try! @zlib.compress(data))
  })
}

///|
test "bench zlib decompress text_1kb" (b : @bench.T) {
  let data = gen_text(1024)
  let compressed = @zlib.compress(data)
  b.bench(name="zlib_decompress_1kb", fn() {
    b.keep(try! @zlib.decompress(compressed))
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

///|
test "bench zlib compress best_speed text_10kb" (b : @bench.T) {
  let data = gen_text(10240)
  b.bench(name="zlib_compress_speed_10kb", fn() {
    b.keep(try! @zlib.compress(data, level=BestSpeed))
  })
}
