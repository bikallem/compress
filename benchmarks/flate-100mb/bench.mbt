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
test "bench flate compress default text_100mb" (b : @bench.T) {
  bench_compress(b, name="flate_compress_default_100mb", 104857600)
}

///|
test "bench flate decompress text_100mb" (b : @bench.T) {
  bench_decompress(b, name="flate_decompress_100mb", 104857600)
}
