///|
test "bench gzip compress default text_1kb" (b : @bench.T) {
  let data = gen_text(1024)
  b.bench(name="gzip_compress_default_1kb", fn() {
    b.keep(try! @gzip.compress(data))
  })
}

///|
test "bench gzip compress default text_10kb" (b : @bench.T) {
  let data = gen_text(10240)
  b.bench(name="gzip_compress_default_10kb", fn() {
    b.keep(try! @gzip.compress(data))
  })
}

///|
test "bench gzip decompress text_1kb" (b : @bench.T) {
  let data = gen_text(1024)
  let compressed = @gzip.compress(data)
  b.bench(name="gzip_decompress_1kb", fn() {
    b.keep(try! @gzip.decompress(compressed))
  })
}

///|
test "bench gzip decompress text_10kb" (b : @bench.T) {
  let data = gen_text(10240)
  let compressed = @gzip.compress(data)
  b.bench(name="gzip_decompress_10kb", fn() {
    b.keep(try! @gzip.decompress(compressed))
  })
}

///|
test "bench gzip compress best_speed text_10kb" (b : @bench.T) {
  let data = gen_text(10240)
  b.bench(name="gzip_compress_speed_10kb", fn() {
    b.keep(try! @gzip.compress(data, level=BestSpeed))
  })
}

///|
test "bench gzip decompress text_100kb" (b : @bench.T) {
  let data = gen_text(102400)
  let compressed = @gzip.compress(data)
  b.bench(name="gzip_decompress_100kb", fn() {
    b.keep(try! @gzip.decompress(compressed))
  })
}

///|
test "bench gzip decompress text_1mb" (b : @bench.T) {
  let data = gen_text(1048576)
  let compressed = @gzip.compress(data)
  b.bench(name="gzip_decompress_1mb", fn() {
    b.keep(try! @gzip.decompress(compressed))
  })
}

///|
test "bench gzip decompress text_10mb" (b : @bench.T) {
  let data = gen_text(10485760)
  let compressed = @gzip.compress(data)
  b.bench(name="gzip_decompress_10mb", fn() {
    b.keep(try! @gzip.decompress(compressed))
  })
}

///|
test "bench gzip decompress text_100mb" (b : @bench.T) {
  let data = gen_text(104857600)
  let compressed = @gzip.compress(data)
  b.bench(name="gzip_decompress_100mb", fn() {
    b.keep(try! @gzip.decompress(compressed))
  })
}

///|
test "bench gzip compress default text_100kb" (b : @bench.T) {
  let data = gen_text(102400)
  b.bench(name="gzip_compress_default_100kb", fn() {
    b.keep(try! @gzip.compress(data))
  })
}

///|
test "bench gzip compress default text_1mb" (b : @bench.T) {
  let data = gen_text(1048576)
  b.bench(name="gzip_compress_default_1mb", fn() {
    b.keep(try! @gzip.compress(data))
  })
}

///|
test "bench gzip compress default text_10mb" (b : @bench.T) {
  let data = gen_text(10485760)
  b.bench(name="gzip_compress_default_10mb", fn() {
    b.keep(try! @gzip.compress(data))
  })
}

///|
test "bench gzip compress default text_100mb" (b : @bench.T) {
  let data = gen_text(104857600)
  b.bench(name="gzip_compress_default_100mb", fn() {
    b.keep(try! @gzip.compress(data))
  })
}
