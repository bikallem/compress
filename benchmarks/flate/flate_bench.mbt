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
fn deflate_with_dict(data : Bytes, dict : Bytes) -> Bytes {
  let d = @fl.Deflater::new(dict~)
  let buf = @buffer.new()
  match d.encode(Some(data)) {
    Data(out) => buf.write_bytes(out)
    _ => ()
  }
  loop d.encode(None) {
    Data(out) => {
      buf.write_bytes(out)
      continue d.encode(None)
    }
    _ => break
  }
  buf.to_bytes()
}

///|
test "bench flate compress default text_1kb" (b : @bench.T) {
  bench_compress(b, name="flate_compress_default_1kb", 1024)
}

///|
test "bench flate compress default text_10kb" (b : @bench.T) {
  bench_compress(b, name="flate_compress_default_10kb", 10240)
}

///|
test "bench flate compress best_speed text_10kb" (b : @bench.T) {
  bench_compress(b, name="flate_compress_speed_10kb", 10240, level=BestSpeed)
}

///|
test "bench flate compress best_compression text_10kb" (b : @bench.T) {
  bench_compress(
    b,
    name="flate_compress_best_10kb",
    10240,
    level=BestCompression,
  )
}

///|
test "bench flate decompress text_10kb" (b : @bench.T) {
  bench_decompress(b, name="flate_decompress_10kb", 10240)
}

///|
test "bench flate compress zeros_10kb" (b : @bench.T) {
  bench_compress(
    b,
    name="flate_compress_zeros_10kb",
    10240,
    gen=@benchmarks.gen_zeros,
  )
}

///|
test "bench flate compress random_10kb" (b : @bench.T) {
  bench_compress(
    b,
    name="flate_compress_random_10kb",
    10240,
    level=BestSpeed,
    gen=@benchmarks.gen_random,
  )
}

///|
test "bench flate compress best_speed text_1kb" (b : @bench.T) {
  bench_compress(b, name="flate_compress_speed_1kb", 1024, level=BestSpeed)
}

///|
test "bench flate decompress text_1kb" (b : @bench.T) {
  bench_decompress(b, name="flate_decompress_1kb", 1024)
}

///|
test "bench flate decompress zeros_10kb" (b : @bench.T) {
  bench_decompress(
    b,
    name="flate_decompress_zeros_10kb",
    10240,
    gen=@benchmarks.gen_zeros,
  )
}

///|
test "bench flate decompress text_100kb" (b : @bench.T) {
  bench_decompress(b, name="flate_decompress_100kb", 102400)
}

///|
test "bench flate decompress text_1mb" (b : @bench.T) {
  bench_decompress(b, name="flate_decompress_1mb", 1048576)
}

///|
test "bench flate decompress text_10mb" (b : @bench.T) {
  bench_decompress(b, name="flate_decompress_10mb", 10485760)
}

///|
test "bench flate decompress text_100mb" (b : @bench.T) {
  bench_decompress(b, name="flate_decompress_100mb", 104857600)
}

///|
test "bench flate compress default text_100kb" (b : @bench.T) {
  bench_compress(b, name="flate_compress_default_100kb", 102400)
}

///|
test "bench flate compress default text_1mb" (b : @bench.T) {
  bench_compress(b, name="flate_compress_default_1mb", 1048576)
}

///|
test "bench flate compress default text_10mb" (b : @bench.T) {
  bench_compress(b, name="flate_compress_default_10mb", 10485760)
}

///|
test "bench flate compress dict text_10kb" (b : @bench.T) {
  let dict : Bytes = b"The quick brown fox jumps over the lazy dog. "
  let data = @benchmarks.gen_text(10240)
  b.bench(name="flate_compress_dict_10kb", fn() {
    b.keep(deflate_with_dict(data, dict))
  })
}

///|
test "bench flate compress dict text_100kb" (b : @bench.T) {
  let dict : Bytes = b"The quick brown fox jumps over the lazy dog. "
  let data = @benchmarks.gen_text(102400)
  b.bench(name="flate_compress_dict_100kb", fn() {
    b.keep(deflate_with_dict(data, dict))
  })
}
