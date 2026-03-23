///|
test "streaming lzw deflater LSB" {
  let original = b"TOBEORNOTTOBEORTOBEORNOT"
  let d = @lzw.Deflater::new(LSB, 8)
  let buf = @blit.Buffer::new()
  match d.encode(Some(original[:])) {
    Ok | End | Error(_) => ()
    Data(out) => buf.write_bytesview(out)
  }
  match d.encode(None) {
    Data(out) => buf.write_bytesview(out)
    End | Ok | Error(_) => ()
  }
  // Drain End if we got Data
  match d.encode(None) {
    End | Ok | Data(_) | Error(_) => ()
  }
  let compressed = buf.to_bytes()
  let decompressed = @lzw.decompress(compressed, LSB, 8)
  assert_eq(decompressed, original)
}

///|
test "streaming lzw inflater LSB" {
  let original = b"TOBEORNOTTOBEORTOBEORNOT"
  let compressed = @lzw.compress(original, LSB, 8)
  let d = @lzw.Inflater::new(LSB, 8)
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
test "streaming lzw inflater with chunked input" {
  let original = Bytes::makei(5000, fn(i) { (i % 251).to_byte() })
  let compressed = @lzw.compress(original, LSB, 8)
  let d = @lzw.Inflater::new(LSB, 8)
  let buf = @blit.Buffer::new()
  let chunk_size = 64
  let mut offset = 0
  loop d.decode() {
    Await => {
      if offset >= compressed.length() {
        fail("unexpected Await: all data consumed")
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
test "streaming lzw deflater + inflater round-trip" {
  let original = Bytes::makei(5000, fn(i) { (i % 251).to_byte() })
  // Compress with deflater in chunks
  let d = @lzw.Deflater::new(LSB, 8)
  let cbuf = @blit.Buffer::new()
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
      Ok | End | Error(_) => ()
      Data(out) => cbuf.write_bytesview(out)
    }
    offset = end
  }
  // Finish
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
  let inf = @lzw.Inflater::new(LSB, 8)
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
test "streaming lzw MSB round-trip" {
  let original = Bytes::makei(3000, fn(i) { (i % 256).to_byte() })
  let d = @lzw.Deflater::new(MSB, 8)
  let cbuf = @blit.Buffer::new()
  match d.encode(Some(original[:])) {
    Ok | End | Error(_) => ()
    Data(out) => cbuf.write_bytesview(out)
  }
  loop d.encode(None) {
    Data(out) => {
      cbuf.write_bytesview(out)
      continue d.encode(None)
    }
    End => break
    Ok | Error(_) => fail("unexpected signal")
  }
  let compressed = cbuf.to_bytes()
  let inf = @lzw.Inflater::new(MSB, 8)
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
