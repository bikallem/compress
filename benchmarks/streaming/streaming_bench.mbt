///|
#borrow(path)
extern "c" fn fopen_read(path : Bytes) -> Int64 = "bench_fopen_read"

///|
#borrow(path)
extern "c" fn fopen_write(path : Bytes) -> Int64 = "bench_fopen_write"

///|
/// Read directly into a Bytes buffer at the given offset. Returns bytes read.
#borrow(buf)
extern "c" fn fread_bytes(
  handle : Int64,
  buf : Bytes,
  offset : Int,
  max_len : Int,
) -> Int = "bench_fread_bytes"

///|
#borrow(data)
extern "c" fn fwrite_bytes(handle : Int64, data : Bytes, len : Int) -> Unit = "bench_fwrite"

///|
extern "c" fn fclose(handle : Int64) -> Unit = "bench_fclose"

///|
#borrow(path)
extern "c" fn remove_file(path : Bytes) -> Unit = "bench_remove"

///|
fn path_cstr(s : String) -> Bytes {
  Bytes::makei(s.length() + 1, fn(i) {
    if i < s.length() {
      s[i].to_int().to_byte()
    } else {
      b'\x00'
    }
  })
}

///|
/// Write Bytes to a file path. Returns the path for chaining.
fn write_to_file(path : String, data : Bytes) -> Unit {
  let h = fopen_write(path_cstr(path))
  if h == 0L {
    abort("cannot open \{path} for writing")
  }
  fwrite_bytes(h, data, data.length())
  fclose(h)
}

///|
/// Compress a file by reading chunks -> deflate -> write output file.
/// Accepts pre-computed C-string paths to avoid allocation per call.
fn compress_file_streaming(
  input_cstr : Bytes,
  output_cstr : Bytes,
  chunk_size : Int,
) -> Unit {
  let ih = fopen_read(input_cstr)
  if ih == 0L {
    abort("cannot open input file")
  }
  let oh = fopen_write(output_cstr)
  if oh == 0L {
    fclose(ih)
    abort("cannot open output file")
  }
  let def = @flate.Deflater::new()
  let buf = Bytes::make(chunk_size, 0)
  // Read and compress chunks — zero allocation per iteration
  while true {
    let n = fread_bytes(ih, buf, 0, chunk_size)
    if n == 0 {
      break
    }
    match def.encode(Some(buf[:n])) {
      Data(out) => fwrite_bytes(oh, out, out.length())
      _ => ()
    }
  }
  // Finalize
  loop def.encode(None) {
    Data(out) => {
      fwrite_bytes(oh, out, out.length())
      continue def.encode(None)
    }
    _ => break
  }
  fclose(ih)
  fclose(oh)
}

///|
/// Decompress a file by reading chunks -> inflate -> write output file.
/// Accepts pre-computed C-string paths to avoid allocation per call.
fn decompress_file_streaming(
  input_cstr : Bytes,
  output_cstr : Bytes,
  chunk_size : Int,
) -> Unit {
  let ih = fopen_read(input_cstr)
  if ih == 0L {
    abort("cannot open input file")
  }
  let oh = fopen_write(output_cstr)
  if oh == 0L {
    fclose(ih)
    abort("cannot open output file")
  }
  let inf = @flate.Inflater::new()
  let buf = Bytes::make(chunk_size, 0)
  // Feed first chunk
  let n = fread_bytes(ih, buf, 0, chunk_size)
  if n > 0 {
    inf.src(buf[:n])
  }
  loop inf.decode() {
    Await => {
      let n = fread_bytes(ih, buf, 0, chunk_size)
      if n > 0 {
        inf.src(buf[:n])
      } else {
        inf.src(b""[:])
      }
      continue inf.decode()
    }
    Data(out) => {
      fwrite_bytes(oh, out, out.length())
      continue inf.decode()
    }
    End => break
    Error(e) => abort("decompress_file_streaming: \{e}")
  }
  fclose(ih)
  fclose(oh)
}

///|
/// Decompress an LZW file by reading chunks -> inflate -> write output file.
/// Accepts pre-computed C-string paths to avoid allocation per call.
fn lzw_decompress_file_streaming(
  input_cstr : Bytes,
  output_cstr : Bytes,
  chunk_size : Int,
) -> Unit {
  let ih = fopen_read(input_cstr)
  if ih == 0L {
    abort("cannot open input file")
  }
  let oh = fopen_write(output_cstr)
  if oh == 0L {
    fclose(ih)
    abort("cannot open output file")
  }
  let inf = try! @lzw.Inflater::new(@lzw.LSB, 8)
  let buf = Bytes::make(chunk_size, 0)
  let n = fread_bytes(ih, buf, 0, chunk_size)
  if n > 0 {
    inf.src(buf[:n])
  }
  loop inf.decode() {
    Await => {
      let n = fread_bytes(ih, buf, 0, chunk_size)
      if n > 0 {
        inf.src(buf[:n])
      } else {
        inf.src(b""[:])
      }
      continue inf.decode()
    }
    Data(out) => {
      fwrite_bytes(oh, out, out.length())
      continue inf.decode()
    }
    @lzw.End => break
    @lzw.Error(e) => abort("lzw_decompress_file_streaming: \{e}")
  }
  fclose(ih)
  fclose(oh)
}

// --- Benchmarks ---

///|
test "bench flate compress streaming 1mb" (b : @bench.T) {
  let data = @benchmarks.gen_text(1048576)
  let input_path = "/tmp/bench_flate_stream_input_1mb.bin"
  let output_path = "/tmp/bench_flate_stream_output_1mb.deflate"
  write_to_file(input_path, data)
  let input_cstr = path_cstr(input_path)
  let output_cstr = path_cstr(output_path)
  b.bench(name="flate_compress_streaming_1mb", fn() {
    compress_file_streaming(input_cstr, output_cstr, 4096)
  })
  remove_file(input_cstr)
  remove_file(output_cstr)
}

///|
test "bench flate compress streaming 10mb" (b : @bench.T) {
  let data = @benchmarks.gen_text(10485760)
  let input_path = "/tmp/bench_flate_stream_input_10mb.bin"
  let output_path = "/tmp/bench_flate_stream_output_10mb.deflate"
  write_to_file(input_path, data)
  let input_cstr = path_cstr(input_path)
  let output_cstr = path_cstr(output_path)
  b.bench(name="flate_compress_streaming_10mb", fn() {
    compress_file_streaming(input_cstr, output_cstr, 4096)
  })
  remove_file(input_cstr)
  remove_file(output_cstr)
}

///|
test "bench flate decompress streaming 1mb" (b : @bench.T) {
  let data = @benchmarks.gen_text(1048576)
  let compressed = @flate.compress(data)
  let input_path = "/tmp/bench_flate_stream_dec_input_1mb.deflate"
  let output_path = "/tmp/bench_flate_stream_dec_output_1mb.bin"
  write_to_file(input_path, compressed)
  let input_cstr = path_cstr(input_path)
  let output_cstr = path_cstr(output_path)
  b.bench(name="flate_decompress_streaming_1mb", fn() {
    decompress_file_streaming(input_cstr, output_cstr, 4096)
  })
  remove_file(input_cstr)
  remove_file(output_cstr)
}

///|
test "bench flate decompress streaming 10mb" (b : @bench.T) {
  let data = @benchmarks.gen_text(10485760)
  let compressed = @flate.compress(data)
  let input_path = "/tmp/bench_flate_stream_dec_input_10mb.deflate"
  let output_path = "/tmp/bench_flate_stream_dec_output_10mb.bin"
  write_to_file(input_path, compressed)
  let input_cstr = path_cstr(input_path)
  let output_cstr = path_cstr(output_path)
  b.bench(name="flate_decompress_streaming_10mb", fn() {
    decompress_file_streaming(input_cstr, output_cstr, 4096)
  })
  remove_file(input_cstr)
  remove_file(output_cstr)
}

///|
test "bench lzw decompress streaming 1mb" (b : @bench.T) {
  let data = @benchmarks.gen_text(1048576)
  let compressed = @lzw.compress(data, @lzw.LSB, 8)
  let input_path = "/tmp/bench_lzw_stream_dec_input_1mb.lzw"
  let output_path = "/tmp/bench_lzw_stream_dec_output_1mb.bin"
  write_to_file(input_path, compressed)
  let input_cstr = path_cstr(input_path)
  let output_cstr = path_cstr(output_path)
  b.bench(name="lzw_decompress_streaming_1mb", fn() {
    lzw_decompress_file_streaming(input_cstr, output_cstr, 4096)
  })
  remove_file(input_cstr)
  remove_file(output_cstr)
}
