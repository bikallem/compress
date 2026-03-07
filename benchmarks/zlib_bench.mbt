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

///|
test "bench zlib decompress text_100kb" (b : @bench.T) {
  let data = gen_text(102400)
  let compressed = @zlib.compress(data)
  b.bench(name="zlib_decompress_100kb", fn() {
    b.keep(try! @zlib.decompress(compressed))
  })
}

///|
test "bench zlib decompress text_1mb" (b : @bench.T) {
  let data = gen_text(1048576)
  let compressed = @zlib.compress(data)
  b.bench(name="zlib_decompress_1mb", fn() {
    b.keep(try! @zlib.decompress(compressed))
  })
}

///|
test "bench zlib decompress text_10mb" (b : @bench.T) {
  let data = gen_text(10485760)
  let compressed = @zlib.compress(data)
  b.bench(name="zlib_decompress_10mb", fn() {
    b.keep(try! @zlib.decompress(compressed))
  })
}

///|
test "bench zlib decompress text_100mb" (b : @bench.T) {
  let data = gen_text(104857600)
  let compressed = @zlib.compress(data)
  b.bench(name="zlib_decompress_100mb", fn() {
    b.keep(try! @zlib.decompress(compressed))
  })
}

///|
test "bench zlib compress default text_100kb" (b : @bench.T) {
  let data = gen_text(102400)
  b.bench(name="zlib_compress_default_100kb", fn() {
    b.keep(try! @zlib.compress(data))
  })
}

///|
test "bench zlib compress default text_1mb" (b : @bench.T) {
  let data = gen_text(1048576)
  b.bench(name="zlib_compress_default_1mb", fn() {
    b.keep(try! @zlib.compress(data))
  })
}

///|
test "bench zlib compress default text_10mb" (b : @bench.T) {
  let data = gen_text(10485760)
  b.bench(name="zlib_compress_default_10mb", fn() {
    b.keep(try! @zlib.compress(data))
  })
}

///|
test "bench zlib compress default text_100mb" (b : @bench.T) {
  let data = gen_text(104857600)
  b.bench(name="zlib_compress_default_100mb", fn() {
    b.keep(try! @zlib.compress(data))
  })
}
