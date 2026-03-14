///|
/// Helper: compress data, then decompress via L1 streaming protocol with chunked input.
fn inflate_streaming(compressed : Bytes, chunk_size : Int) -> Bytes {
  let inf = @flate.Inflater::new()
  let buf = @buffer.new()
  let mut offset = 0
  let len = compressed.length()
  // Feed first chunk
  let first_n = if len < chunk_size { len } else { chunk_size }
  inf.src(Bytes::makei(first_n, fn(i) { compressed[offset + i] }))
  offset += first_n
  loop inf.decode() {
    Await => {
      let n = if len - offset < chunk_size { len - offset } else { chunk_size }
      if n > 0 {
        inf.src(Bytes::makei(n, fn(i) { compressed[offset + i] }))
        offset += n
      } else {
        inf.src(b"")
      }
      continue inf.decode()
    }
    Data(out) => {
      buf.write_bytes(out)
      continue inf.decode()
    }
    End => break buf.to_bytes()
    Error(e) => abort("inflate_streaming: \{e}")
  }
}

///|
/// Helper: compress via L1 streaming protocol with chunked input.
fn deflate_streaming(data : Bytes, chunk_size : Int) -> Bytes {
  let def = @flate.Deflater::new()
  let buf = @buffer.new()
  let mut offset = 0
  let len = data.length()
  while offset < len {
    let n = if len - offset < chunk_size { len - offset } else { chunk_size }
    let chunk = Bytes::makei(n, fn(i) { data[offset + i] })
    offset += n
    match def.encode(Some(chunk)) {
      Data(out) => buf.write_bytes(out)
      _ => ()
    }
  }
  loop def.encode(None) {
    Data(out) => {
      buf.write_bytes(out)
      continue def.encode(None)
    }
    _ => break
  }
  buf.to_bytes()
}

///|
/// Helper: decompress LZW via L1 streaming protocol with chunked input.
fn lzw_inflate_streaming(compressed : Bytes, chunk_size : Int) -> Bytes {
  let inf = try! @lzw.Inflater::new(@lzw.LSB, 8)
  let buf = @buffer.new()
  let mut offset = 0
  let len = compressed.length()
  let first_n = if len < chunk_size { len } else { chunk_size }
  inf.src(Bytes::makei(first_n, fn(i) { compressed[offset + i] }))
  offset += first_n
  loop inf.decode() {
    Await => {
      let n = if len - offset < chunk_size { len - offset } else { chunk_size }
      if n > 0 {
        inf.src(Bytes::makei(n, fn(i) { compressed[offset + i] }))
        offset += n
      } else {
        inf.src(b"")
      }
      continue inf.decode()
    }
    Data(out) => {
      buf.write_bytes(out)
      continue inf.decode()
    }
    @lzw.End => break buf.to_bytes()
    @lzw.Error(e) => abort("lzw_inflate_streaming: \{e}")
  }
}

///|
test "bench flate decompress streaming 1mb" (b : @bench.T) {
  let data = gen_text(1048576)
  let compressed = @flate.compress(data)
  b.bench(name="flate_decompress_streaming_1mb", fn() {
    b.keep(inflate_streaming(compressed, 4096))
  })
}

///|
test "bench flate compress streaming 1mb" (b : @bench.T) {
  let data = gen_text(1048576)
  b.bench(name="flate_compress_streaming_1mb", fn() {
    b.keep(deflate_streaming(data, 4096))
  })
}

///|
test "bench lzw decompress streaming 1mb" (b : @bench.T) {
  let data = gen_text(1048576)
  let compressed = @lzw.compress(data, @lzw.LSB, 8)
  b.bench(name="lzw_decompress_streaming_1mb", fn() {
    b.keep(lzw_inflate_streaming(compressed, 4096))
  })
}

///|
test "bench flate decompress streaming 10mb" (b : @bench.T) {
  let data = gen_text(10485760)
  let compressed = @flate.compress(data)
  b.bench(name="flate_decompress_streaming_10mb", fn() {
    b.keep(inflate_streaming(compressed, 4096))
  })
}

///|
test "bench flate compress streaming 10mb" (b : @bench.T) {
  let data = gen_text(10485760)
  b.bench(name="flate_compress_streaming_10mb", fn() {
    b.keep(deflate_streaming(data, 4096))
  })
}
