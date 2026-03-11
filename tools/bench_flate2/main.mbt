///|
#borrow(path)
extern "c" fn fopen_read(path : Bytes) -> Int64 = "bench_fopen_read"

///|
#borrow(path)
extern "c" fn fopen_write(path : Bytes) -> Int64 = "bench_fopen_write"

///|
#borrow(buf)
extern "c" fn fread_into(
  handle : Int64,
  buf : FixedArray[Byte],
  max_len : Int,
) -> Int = "bench_fread"

///|
#borrow(data)
extern "c" fn fwrite_bytes(
  handle : Int64,
  data : Bytes,
  len : Int,
) -> Unit = "bench_fwrite"

///|
extern "c" fn fclose(handle : Int64) -> Unit = "bench_fclose"

///|
extern "c" fn file_size(handle : Int64) -> Int64 = "bench_file_size"

///|
extern "c" fn clock_ns() -> Int64 = "bench_clock_ns"

///|
extern "c" fn rss_bytes() -> Int64 = "bench_rss_bytes"

///|
const CHUNK_SIZE : Int = 65536

///|
fn path_to_cstr(s : String) -> Bytes {
  // Convert ASCII string to null-terminated C string.
  // s[i] returns UTF-16 code units; for ASCII paths the low byte is the UTF-8 byte.
  Bytes::makei(s.length() + 1, fn(i) {
    if i < s.length() {
      s[i].to_int().to_byte()
    } else {
      b'\x00'
    }
  })
}

///|
#cfg(target="native")
fn main {
  let args = @env.args()
  if args.length() < 2 {
    println(
      "Usage: bench_flate2 <input_path> [compressed_path] [decompressed_path]",
    )
    return
  }
  let input_path = args[1]
  let compressed_path = if args.length() > 2 {
    args[2]
  } else {
    "/tmp/bench_flate2.deflate"
  }
  let decompressed_path = if args.length() > 3 {
    args[3]
  } else {
    "/tmp/bench_flate2.roundtrip"
  }
  // Get input size
  let fin = fopen_read(path_to_cstr(input_path))
  if fin == 0L {
    println("ERROR: cannot open \{input_path}")
    return
  }
  let input_size = file_size(fin)
  fclose(fin)
  println("Input: \{input_path} (\{input_size / (1024L * 1024L)} MB)")
  // Compress
  let rss_before_compress = rss_bytes()
  let t0 = clock_ns()
  let compressed_size = compress_file(input_path, compressed_path)
  let t1 = clock_ns()
  let rss_after_compress = rss_bytes()
  let compress_ms = (t1 - t0) / 1_000_000L
  let compress_throughput = if compress_ms > 0L {
    input_size * 1000L / compress_ms / (1024L * 1024L)
  } else {
    0L
  }
  let ratio = compressed_size * 100L / input_size
  println("")
  println("=== COMPRESS (MoonBit flate2, level 6) ===")
  println(
    "Output:     \{compressed_size} bytes (\{compressed_size / (1024L * 1024L)} MB, \{ratio}%)",
  )
  println("Time:       \{compress_ms}ms")
  println("Throughput: \{compress_throughput} MB/s")
  println("RSS before: \{rss_before_compress / (1024L * 1024L)} MB")
  println("RSS after:  \{rss_after_compress / (1024L * 1024L)} MB")
  // Decompress
  let rss_before_decompress = rss_bytes()
  let t2 = clock_ns()
  let decompressed_size = decompress_file(compressed_path, decompressed_path)
  let t3 = clock_ns()
  let rss_after_decompress = rss_bytes()
  let decompress_ms = (t3 - t2) / 1_000_000L
  let decompress_throughput = if decompress_ms > 0L {
    decompressed_size * 1000L / decompress_ms / (1024L * 1024L)
  } else {
    0L
  }
  println("")
  println("=== DECOMPRESS (MoonBit flate2) ===")
  println(
    "Output:     \{decompressed_size} bytes (\{decompressed_size / (1024L * 1024L)} MB)",
  )
  println("Time:       \{decompress_ms}ms")
  println("Throughput: \{decompress_throughput} MB/s")
  println("RSS before: \{rss_before_decompress / (1024L * 1024L)} MB")
  println("RSS after:  \{rss_after_decompress / (1024L * 1024L)} MB")
  // Validate
  println("")
  println("=== VALIDATE ===")
  if decompressed_size != input_size {
    println(
      "FAIL: size mismatch: got \{decompressed_size}, want \{input_size}",
    )
    return
  }
  let ok = validate_files(input_path, decompressed_path, input_size)
  if ok {
    println("PASS: round-trip matches")
  }
}

///|
#cfg(target="wasm-gc")
fn main {
  println("This tool requires --target native")
}

///|
fn compress_file(input_path : String, output_path : String) -> Int64 {
  let fin = fopen_read(path_to_cstr(input_path))
  let fout = fopen_write(path_to_cstr(output_path))
  let deflater = @flate2.Deflater::new()
  let read_buf = FixedArray::make(CHUNK_SIZE, b'\x00')
  let mut total_out = 0L
  // Feed chunks
  while true {
    let n = fread_into(fin, read_buf, CHUNK_SIZE)
    if n <= 0 {
      break
    }
    let chunk = read_buf.unsafe_reinterpret_as_bytes()
    let input = if n == CHUNK_SIZE {
      chunk
    } else {
      Bytes::makei(n, fn(i) { chunk[i] })
    }
    match deflater.encode(Some(input)) {
      Ok => ()
      Data(output) => {
        fwrite_bytes(fout, output, output.length())
        total_out += output.length().to_int64()
      }
      End => break
      Error(e) => {
        println("COMPRESS ERROR: \{e}")
        break
      }
    }
  }
  // Finish
  match deflater.encode(None) {
    Data(output) => {
      fwrite_bytes(fout, output, output.length())
      total_out += output.length().to_int64()
    }
    End => ()
    _ => ()
  }
  fclose(fin)
  fclose(fout)
  total_out
}

///|
fn decompress_file(input_path : String, output_path : String) -> Int64 {
  let fin = fopen_read(path_to_cstr(input_path))
  let fout = fopen_write(path_to_cstr(output_path))
  let inflater = @flate2.Inflater::new()
  let read_buf = FixedArray::make(CHUNK_SIZE, b'\x00')
  let mut total_out = 0L
  loop inflater.decode() {
    Await => {
      let n = fread_into(fin, read_buf, CHUNK_SIZE)
      if n <= 0 {
        println("DECOMPRESS ERROR: unexpected EOF")
        break ()
      }
      let input = Bytes::makei(n, fn(i) { read_buf[i] })
      inflater.src(input)
      continue inflater.decode()
    }
    Data(output) => {
      fwrite_bytes(fout, output, output.length())
      total_out += output.length().to_int64()
      continue inflater.decode()
    }
    End => ()
    Error(e) => println("DECOMPRESS ERROR: \{e}")
  }
  fclose(fin)
  fclose(fout)
  total_out
}

///|
fn validate_files(
  path_a : String,
  path_b : String,
  size : Int64,
) -> Bool {
  let fa = fopen_read(path_to_cstr(path_a))
  let fb = fopen_read(path_to_cstr(path_b))
  let buf_a = FixedArray::make(CHUNK_SIZE, b'\x00')
  let buf_b = FixedArray::make(CHUNK_SIZE, b'\x00')
  let bytes_a = buf_a.unsafe_reinterpret_as_bytes()
  let bytes_b = buf_b.unsafe_reinterpret_as_bytes()
  let mut offset = 0L
  let mut ok = true
  while offset < size {
    let na = fread_into(fa, buf_a, CHUNK_SIZE)
    let nb = fread_into(fb, buf_b, CHUNK_SIZE)
    if na != nb {
      println("FAIL: read size mismatch at offset \{offset}")
      ok = false
      break
    }
    for i in 0..<na {
      if bytes_a[i] != bytes_b[i] {
        println("FAIL: mismatch at byte \{offset + i.to_int64()}")
        ok = false
        break
      }
    }
    if not(ok) {
      break
    }
    offset += na.to_int64()
  }
  fclose(fa)
  fclose(fb)
  ok
}
