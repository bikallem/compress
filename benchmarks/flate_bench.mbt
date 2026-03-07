///|
test "bench flate compress default text_1kb" (b : @bench.T) {
  let data = gen_text(1024)
  b.bench(name="flate_compress_default_1kb", fn() {
    b.keep(try! @flate.compress(data))
  })
}

///|
test "bench flate compress default text_10kb" (b : @bench.T) {
  let data = gen_text(10240)
  b.bench(name="flate_compress_default_10kb", fn() {
    b.keep(try! @flate.compress(data))
  })
}

///|
test "bench flate compress best_speed text_10kb" (b : @bench.T) {
  let data = gen_text(10240)
  b.bench(name="flate_compress_speed_10kb", fn() {
    b.keep(try! @flate.compress(data, level=BestSpeed))
  })
}

///|
test "bench flate compress best_compression text_10kb" (b : @bench.T) {
  let data = gen_text(10240)
  b.bench(name="flate_compress_best_10kb", fn() {
    b.keep(try! @flate.compress(data, level=BestCompression))
  })
}

///|
test "bench flate decompress text_10kb" (b : @bench.T) {
  let data = gen_text(10240)
  let compressed = @flate.compress(data)
  b.bench(name="flate_decompress_10kb", fn() {
    b.keep(try! @flate.decompress(compressed))
  })
}

///|
test "bench flate compress zeros_10kb" (b : @bench.T) {
  let data = gen_zeros(10240)
  b.bench(name="flate_compress_zeros_10kb", fn() {
    b.keep(try! @flate.compress(data))
  })
}

///|
test "bench flate compress random_10kb" (b : @bench.T) {
  let data = gen_random(10240)
  b.bench(name="flate_compress_random_10kb", fn() {
    b.keep(try! @flate.compress(data, level=BestSpeed))
  })
}

///|
test "bench flate compress best_speed text_1kb" (b : @bench.T) {
  let data = gen_text(1024)
  b.bench(name="flate_compress_speed_1kb", fn() {
    b.keep(try! @flate.compress(data, level=BestSpeed))
  })
}

///|
test "bench flate decompress text_1kb" (b : @bench.T) {
  let data = gen_text(1024)
  let compressed = @flate.compress(data)
  b.bench(name="flate_decompress_1kb", fn() {
    b.keep(try! @flate.decompress(compressed))
  })
}

///|
test "bench flate decompress zeros_10kb" (b : @bench.T) {
  let data = gen_zeros(10240)
  let compressed = @flate.compress(data)
  b.bench(name="flate_decompress_zeros_10kb", fn() {
    b.keep(try! @flate.decompress(compressed))
  })
}

///|
test "bench flate decompress text_100kb" (b : @bench.T) {
  let data = gen_text(102400)
  let compressed = @flate.compress(data)
  b.bench(name="flate_decompress_100kb", fn() {
    b.keep(try! @flate.decompress(compressed))
  })
}

///|
test "bench flate decompress text_1mb" (b : @bench.T) {
  let data = gen_text(1048576)
  let compressed = @flate.compress(data)
  b.bench(name="flate_decompress_1mb", fn() {
    b.keep(try! @flate.decompress(compressed))
  })
}

///|
test "bench flate decompress text_10mb" (b : @bench.T) {
  let data = gen_text(10485760)
  let compressed = @flate.compress(data)
  b.bench(name="flate_decompress_10mb", fn() {
    b.keep(try! @flate.decompress(compressed))
  })
}
