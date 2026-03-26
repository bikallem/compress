///|
test "streaming bzip2 deflater" {
  let original = b"Hello, World! This is a test of bzip2 streaming."
  let d = @bzip2.Deflater::new()
  let buf = @blit.Buffer::new()
  match d.encode(Some(original[:])) {
    Ok | Data(_) | End | Error(_) => ()
  }
  loop d.encode(None) {
    Data(out) => {
      buf.write_bytesview(out)
      continue d.encode(None)
    }
    End => break
    Ok | Error(_) => fail("unexpected signal from encode(None)")
  }
  let compressed = buf.to_bytes()
  let decompressed = @bzip2.decompress(compressed)
  assert_eq(decompressed, original)
}

///|
test "streaming bzip2 inflater" {
  let original = b"Hello, World! This is a test of bzip2 streaming."
  let compressed = @bzip2.compress(original)
  let d = @bzip2.Inflater::new()
  d.src(compressed[:])
  let buf = @blit.Buffer::new()
  loop d.decode() {
    Await => fail("unexpected Await: all data should be available")
    Data(out) => {
      buf.write_bytesview(out)
      continue d.decode()
    }
    End => break
    Error(e) => raise e
  }
  assert_eq(buf.to_bytes(), original)
}

///|
test "streaming bzip2 inflater with chunked input" {
  let original = Bytes::makei(3000, fn(i) { (i % 251).to_byte() })
  let compressed = @bzip2.compress(original)
  let d = @bzip2.Inflater::new()
  let buf = @blit.Buffer::new()
  let chunk_size = 64
  let mut offset = 0
  loop d.decode() {
    Await => {
      if offset >= compressed.length() {
        fail("unexpected Await: all data consumed")
        break
      }
      let end = if offset + chunk_size > compressed.length() {
        compressed.length()
      } else {
        offset + chunk_size
      }
      let chunk = Bytes::makei(end - offset, fn(i) { compressed[offset + i] })
      d.src(chunk[:])
      offset = end
      continue d.decode()
    }
    Data(out) => {
      buf.write_bytesview(out)
      continue d.decode()
    }
    End => break
    Error(e) => raise e
  }
  assert_eq(buf.to_bytes(), original)
}

///|
test "streaming bzip2 deflater + inflater round-trip" {
  let original = Bytes::makei(5000, fn(i) { (i % 251).to_byte() })
  // Compress with deflater in chunks
  let d = @bzip2.Deflater::new()
  let chunk_size = 500
  let mut offset = 0
  while offset < original.length() {
    let end = if offset + chunk_size > original.length() {
      original.length()
    } else {
      offset + chunk_size
    }
    let chunk = Bytes::makei(end - offset, fn(i) { original[offset + i] })
    match d.encode(Some(chunk[:])) {
      Ok | Data(_) | End | Error(_) => ()
    }
    offset = end
  }
  // Finish
  let cbuf = @blit.Buffer::new()
  loop d.encode(None) {
    Data(out) => {
      cbuf.write_bytesview(out)
      continue d.encode(None)
    }
    End => break
    Ok | Error(_) => fail("unexpected signal")
  }
  // Decompress with inflater
  let compressed = cbuf.to_bytes()
  let inf = @bzip2.Inflater::new()
  inf.src(compressed[:])
  let dbuf = @blit.Buffer::new()
  loop inf.decode() {
    Await => fail("unexpected Await")
    Data(out) => {
      dbuf.write_bytesview(out)
      continue inf.decode()
    }
    End => break
    Error(e) => raise e
  }
  assert_eq(dbuf.to_bytes(), original)
}

///|
test "streaming bzip2 inflater byte-at-a-time" {
  let original = b"Byte-at-a-time streaming stress test for bzip2 inflater!"
  let compressed = @bzip2.compress(original)
  let d = @bzip2.Inflater::new()
  let buf = @blit.Buffer::new()
  let mut offset = 0
  loop d.decode() {
    Await => {
      if offset >= compressed.length() {
        fail("unexpected Await: all data consumed")
      }
      let chunk = Bytes::makei(1, fn(_i) { compressed[offset] })
      d.src(chunk[:])
      offset += 1
      continue d.decode()
    }
    Data(out) => {
      buf.write_bytesview(out)
      continue d.decode()
    }
    End => break
    Error(e) => raise e
  }
  assert_eq(buf.to_bytes(), original)
}

///|
test "streaming bzip2 deflater emits blocks incrementally" {
  // Use level 1 (100KB blocks) and feed 250KB to get at least 2 block flushes
  let d = @bzip2.Deflater::new(level=1)
  let chunk = Bytes::makei(50000, fn(i) { (i % 251).to_byte() })
  let cbuf = @blit.Buffer::new()
  let mut data_signals = 0
  // Feed 5 chunks of 50KB = 250KB total, triggers 2 block flushes
  for _ in 0..<5 {
    match d.encode(Some(chunk[:])) {
      Ok => ()
      Data(out) => {
        cbuf.write_bytesview(out)
        data_signals += 1
      }
      End | Error(_) => fail("unexpected signal")
    }
  }
  // Should have gotten at least 1 Data signal from mid-stream block flushes
  assert_true(data_signals >= 1)
  // Finish
  loop d.encode(None) {
    Data(out) => {
      cbuf.write_bytesview(out)
      continue d.encode(None)
    }
    End => break
    Ok | Error(_) => fail("unexpected signal from encode(None)")
  }
  // Verify round-trip
  let original = {
    let b = @blit.Buffer::new()
    for _ in 0..<5 {
      b.write_bytes(chunk)
    }
    b.to_bytes()
  }
  let decompressed = @bzip2.decompress(cbuf.to_bytes())
  assert_eq(decompressed, original)
}

///|
test "streaming bzip2 inflater consumes buffered concatenated streams" {
  let compressed = @bzip2.compress(b"first stream") +
    @bzip2.compress(b"second stream")
  let d = @bzip2.Inflater::new()
  let buf = @blit.Buffer::new()
  d.src(compressed[:])
  loop d.decode() {
    Await => fail("unexpected Await with full concatenated bzip2 input")
    Data(out) => {
      buf.write_bytesview(out)
      continue d.decode()
    }
    End => break
    Error(e) => raise e
  }
  assert_eq(buf.to_bytes(), b"first streamsecond stream")
}
