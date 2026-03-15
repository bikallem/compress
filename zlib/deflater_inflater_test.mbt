///|
test "streaming zlib deflater round-trip" {
  let original = b"Hello, World! This is a test of zlib streaming."
  let d = @zlib.Deflater::new()
  let buf = @buffer.new()
  // Feed data
  match d.encode(Some(original[:])) {
    Data(out) => buf.write_bytes(out)
    Ok => ()
    _ => fail("unexpected signal during encode")
  }
  // Finish
  loop d.encode(None) {
    Data(out) => {
      buf.write_bytes(out)
      continue d.encode(None)
    }
    End => break
    _ => {
      fail("unexpected signal during finish")
      break
    }
  }
  let compressed = buf.to_bytes()
  let decompressed = @zlib.decompress(compressed)
  assert_eq(decompressed, original)
}

///|
test "streaming zlib inflater round-trip" {
  let original = b"Hello, World! This is a test of zlib streaming decompression."
  let compressed = @zlib.compress(original)
  let d = @zlib.Inflater::new()
  let buf = @buffer.new()
  // Feed all compressed data at once
  d.src(compressed[:])
  loop d.decode() {
    Await => {
      fail("unexpected Await with all data provided")
      break
    }
    Data(out) => {
      buf.write_bytes(out)
      continue d.decode()
    }
    End => break
    Error(e) => {
      fail("error: \{e}")
      break
    }
  }
  assert_eq(buf.to_bytes(), original)
}

///|
test "streaming zlib inflater with chunked input" {
  let original = Bytes::makei(5000, fn(i) { (i % 251).to_byte() })
  let compressed = @zlib.compress(original)
  let d = @zlib.Inflater::new()
  let buf = @buffer.new()
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
      buf.write_bytes(out)
      continue d.decode()
    }
    End => break
    Error(e) => {
      fail("error: \{e}")
      break
    }
  }
  assert_eq(buf.to_bytes(), original)
}

///|
test "streaming zlib deflater + inflater round-trip" {
  let original = Bytes::makei(5000, fn(i) { (i % 251).to_byte() })
  // Compress with deflater
  let d = @zlib.Deflater::new()
  let cbuf = @buffer.new()
  match d.encode(Some(original[:])) {
    Data(out) => cbuf.write_bytes(out)
    Ok => ()
    _ => fail("unexpected signal")
  }
  loop d.encode(None) {
    Data(out) => {
      cbuf.write_bytes(out)
      continue d.encode(None)
    }
    End => break
    _ => {
      fail("unexpected signal")
      break
    }
  }
  let compressed = cbuf.to_bytes()
  // Decompress with inflater
  let inf = @zlib.Inflater::new()
  let dbuf = @buffer.new()
  inf.src(compressed[:])
  loop inf.decode() {
    Await => {
      fail("unexpected Await")
      break
    }
    Data(out) => {
      dbuf.write_bytes(out)
      continue inf.decode()
    }
    End => break
    Error(e) => {
      fail("error: \{e}")
      break
    }
  }
  assert_eq(dbuf.to_bytes(), original)
}

///|
test "streaming zlib deflater with compression levels" {
  let original = Bytes::makei(1000, fn(i) { (i % 26 + 65).to_byte() })
  let d = @zlib.Deflater::new(level=NoCompression)
  let buf = @buffer.new()
  match d.encode(Some(original[:])) {
    Data(out) => buf.write_bytes(out)
    Ok => ()
    _ => fail("unexpected signal")
  }
  loop d.encode(None) {
    Data(out) => {
      buf.write_bytes(out)
      continue d.encode(None)
    }
    End => break
    _ => {
      fail("unexpected signal")
      break
    }
  }
  let decompressed = @zlib.decompress(buf.to_bytes())
  assert_eq(decompressed, original)
}
