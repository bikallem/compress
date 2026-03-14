///|
/// Generate repeated text data of approximately the given size.
fn gen_text(size : Int) -> Bytes {
  let phrase = b"The quick brown fox jumps over the lazy dog. "
  Bytes::makei(size, fn(i) { phrase[i % phrase.length()] })
}

///|
/// Generate all-zero data.
fn gen_zeros(size : Int) -> Bytes {
  Bytes::make(size, 0)
}

///|
/// Generate pseudo-random data (incompressible).
/// Uses glibc LCG constants for reproducible output; >>16 avoids low-bit patterns.
fn gen_random(size : Int) -> Bytes {
  let buf = FixedArray::make(size, b'\x00')
  for i = 0, state = 0x12345678U; i < size; {
    let next_state = state * 1103515245U + 12345U
    buf[i] = ((next_state >> 16) & 0xFFU).to_byte()
    continue i + 1, next_state
  }
  Bytes::from_array(buf)
}

///|
fn bench_flate_compress(
  b : @bench.T,
  name~ : String,
  size : Int,
  level? : @flate.CompressionLevel = DefaultCompression,
  gen? : (Int) -> Bytes = gen_text,
) -> Unit {
  let data = gen(size)
  b.bench(name~, fn() { b.keep(try! @flate.compress(data, level~)) })
}

///|
fn bench_flate_decompress(
  b : @bench.T,
  name~ : String,
  size : Int,
  gen? : (Int) -> Bytes = gen_text,
) -> Unit raise {
  let data = gen(size)
  let compressed = @flate.compress(data)
  b.bench(name~, fn() { b.keep(try! @flate.decompress(compressed)) })
}

///|
fn bench_gzip_compress(
  b : @bench.T,
  name~ : String,
  size : Int,
  level? : @flate.CompressionLevel = DefaultCompression,
) -> Unit {
  let data = gen_text(size)
  b.bench(name~, fn() { b.keep(try! @gzip.compress(data, level~)) })
}

///|
fn bench_gzip_decompress(
  b : @bench.T,
  name~ : String,
  size : Int,
) -> Unit raise {
  let data = gen_text(size)
  let compressed = @gzip.compress(data)
  b.bench(name~, fn() { b.keep(try! @gzip.decompress(compressed)) })
}

///|
fn bench_zlib_compress(
  b : @bench.T,
  name~ : String,
  size : Int,
  level? : @flate.CompressionLevel = DefaultCompression,
) -> Unit {
  let data = gen_text(size)
  b.bench(name~, fn() { b.keep(try! @zlib.compress(data, level~)) })
}

///|
fn bench_zlib_decompress(
  b : @bench.T,
  name~ : String,
  size : Int,
) -> Unit raise {
  let data = gen_text(size)
  let compressed = @zlib.compress(data)
  b.bench(name~, fn() { b.keep(try! @zlib.decompress(compressed)) })
}

///|
fn bench_lzw_compress(b : @bench.T, name~ : String, size : Int) -> Unit {
  let data = gen_text(size)
  b.bench(name~, fn() { b.keep(try! @lzw.compress(data, @lzw.LSB, 8)) })
}

///|
fn bench_lzw_decompress(b : @bench.T, name~ : String, size : Int) -> Unit raise {
  let data = gen_text(size)
  let compressed = @lzw.compress(data, @lzw.LSB, 8)
  b.bench(name~, fn() { b.keep(try! @lzw.decompress(compressed, @lzw.LSB, 8)) })
}

///|
fn bench_bzip2_compress(b : @bench.T, name~ : String, size : Int) -> Unit {
  let data = gen_text(size)
  b.bench(name~, fn() { b.keep(try! @bzip2.compress(data)) })
}

///|
fn bench_bzip2_decompress(
  b : @bench.T,
  name~ : String,
  size : Int,
) -> Unit raise {
  let data = gen_text(size)
  let compressed = @bzip2.compress(data)
  // Validate roundtrip before benchmarking
  let check = @bzip2.decompress(compressed)
  guard check.length() == data.length() else {
    fail("bzip2 roundtrip size mismatch: \{check.length()} != \{data.length()}")
  }
  b.bench(name~, fn() { b.keep(try! @bzip2.decompress(compressed)) })
}
