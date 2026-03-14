///|
fn compress_setup(
  size : Int,
  gen? : (Int) -> Bytes = @benchmarks.gen_text,
) -> Bytes raise {
  @fl.compress(gen(size))
}

///|
fn bench_compress(
  b : @bench.T,
  name~ : String,
  size : Int,
  level? : @fl.CompressionLevel = DefaultCompression,
  gen? : (Int) -> Bytes = @benchmarks.gen_text,
) -> Unit {
  let data = gen(size)
  b.bench(name~, fn() { b.keep(try! @fl.compress(data, level~)) })
}

///|
fn bench_decompress(
  b : @bench.T,
  name~ : String,
  size : Int,
  gen? : (Int) -> Bytes = @benchmarks.gen_text,
) -> Unit raise {
  let compressed = compress_setup(size, gen~)
  b.bench(name~, fn() { b.keep(try! @fl.decompress(compressed)) })
}

///|
test "bench flate compress default text_1kb" (b : @bench.T) {
  bench_compress(b, name="flate_compress_default_1kb", 1024)
}

///|
test "bench flate decompress text_1kb" (b : @bench.T) {
  bench_decompress(b, name="flate_decompress_1kb", 1024)
}

///|
test "bench flate compress best_speed text_1kb" (b : @bench.T) {
  bench_compress(b, name="flate_compress_speed_1kb", 1024, level=BestSpeed)
}
