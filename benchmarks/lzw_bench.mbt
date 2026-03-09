///|
test "bench lzw compress LSB text_1kb" (b : @bench.T) {
  let data = gen_text(1024)
  b.bench(name="lzw_compress_lsb_1kb", fn() {
    b.keep(try! @lzw.compress_bytes(data, @lzw.LSB))
  })
}

///|
test "bench lzw compress LSB text_10kb" (b : @bench.T) {
  let data = gen_text(10240)
  b.bench(name="lzw_compress_lsb_10kb", fn() {
    b.keep(try! @lzw.compress_bytes(data, @lzw.LSB))
  })
}

///|
test "bench lzw decompress LSB text_1kb" (b : @bench.T) {
  let data = gen_text(1024)
  let compressed = try! @lzw.compress_bytes(data, @lzw.LSB)
  b.bench(name="lzw_decompress_lsb_1kb", fn() {
    b.keep(try! @lzw.decompress_bytes(compressed, @lzw.LSB))
  })
}

///|
test "bench lzw decompress LSB text_10kb" (b : @bench.T) {
  let data = gen_text(10240)
  let compressed = try! @lzw.compress_bytes(data, @lzw.LSB)
  b.bench(name="lzw_decompress_lsb_10kb", fn() {
    b.keep(try! @lzw.decompress_bytes(compressed, @lzw.LSB))
  })
}

///|
test "bench lzw decompress LSB text_100kb" (b : @bench.T) {
  let data = gen_text(102400)
  let compressed = try! @lzw.compress_bytes(data, @lzw.LSB)
  b.bench(name="lzw_decompress_lsb_100kb", fn() {
    b.keep(try! @lzw.decompress_bytes(compressed, @lzw.LSB))
  })
}

///|
test "bench lzw decompress LSB text_1mb" (b : @bench.T) {
  let data = gen_text(1048576)
  let compressed = try! @lzw.compress_bytes(data, @lzw.LSB)
  b.bench(name="lzw_decompress_lsb_1mb", fn() {
    b.keep(try! @lzw.decompress_bytes(compressed, @lzw.LSB))
  })
}

///|
test "bench lzw decompress LSB text_10mb" (b : @bench.T) {
  let data = gen_text(10485760)
  let compressed = try! @lzw.compress_bytes(data, @lzw.LSB)
  b.bench(name="lzw_decompress_lsb_10mb", fn() {
    b.keep(try! @lzw.decompress_bytes(compressed, @lzw.LSB))
  })
}

///|
test "bench lzw decompress LSB text_100mb" (b : @bench.T) {
  let data = gen_text(104857600)
  let compressed = try! @lzw.compress_bytes(data, @lzw.LSB)
  b.bench(name="lzw_decompress_lsb_100mb", fn() {
    b.keep(try! @lzw.decompress_bytes(compressed, @lzw.LSB))
  })
}

///|
test "bench lzw compress LSB text_100kb" (b : @bench.T) {
  let data = gen_text(102400)
  b.bench(name="lzw_compress_lsb_100kb", fn() {
    b.keep(try! @lzw.compress_bytes(data, @lzw.LSB))
  })
}

///|
test "bench lzw compress LSB text_1mb" (b : @bench.T) {
  let data = gen_text(1048576)
  b.bench(name="lzw_compress_lsb_1mb", fn() {
    b.keep(try! @lzw.compress_bytes(data, @lzw.LSB))
  })
}

///|
test "bench lzw compress LSB text_10mb" (b : @bench.T) {
  let data = gen_text(10485760)
  b.bench(name="lzw_compress_lsb_10mb", fn() {
    b.keep(try! @lzw.compress_bytes(data, @lzw.LSB))
  })
}

///|
test "bench lzw compress LSB text_100mb" (b : @bench.T) {
  let data = gen_text(104857600)
  b.bench(name="lzw_compress_lsb_100mb", fn() {
    b.keep(try! @lzw.compress_bytes(data, @lzw.LSB))
  })
}
