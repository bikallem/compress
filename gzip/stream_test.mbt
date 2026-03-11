///|
test "streaming gzip deflater round-trip" {
  let original = b"Hello, World! This is a test of gzip streaming."
  let d = @gzip.Deflater::new()
  let buf = @buffer.new()
  match d.encode(Some(original)) {
    Data(out) => buf.write_bytes(out)
    Ok => ()
    _ => fail("unexpected signal during encode")
  }
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
  let (decompressed, _) = @gzip.decompress(compressed)
  assert_eq(decompressed, original)
}

///|
test "streaming gzip inflater round-trip" {
  let original = b"Hello, World! This is a test of gzip streaming decompression."
  let compressed = @gzip.compress(original)
  let d = @gzip.Inflater::new()
  let buf = @buffer.new()
  d.src(compressed)
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
test "streaming gzip inflater with chunked input" {
  let original = Bytes::makei(5000, fn(i) { (i % 251).to_byte() })
  let compressed = @gzip.compress(original)
  let d = @gzip.Inflater::new()
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
      let chunk = Bytes::makei(end - offset, fn(i) {
        compressed[offset + i]
      })
      d.src(chunk)
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
test "streaming gzip deflater + inflater round-trip" {
  let original = Bytes::makei(5000, fn(i) { (i % 251).to_byte() })
  // Compress with deflater
  let d = @gzip.Deflater::new()
  let cbuf = @buffer.new()
  match d.encode(Some(original)) {
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
  let inf = @gzip.Inflater::new()
  let dbuf = @buffer.new()
  inf.src(compressed)
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
test "streaming gzip inflater exposes header" {
  let original = b"test data"
  let header = @gzip.Header::{
    name: "test.txt",
    comment: "a comment",
    extra: Bytes::default(),
    mod_time: 12345U,
    os: b'\xFF',
  }
  let compressed = @gzip.compress(original, header~)
  let d = @gzip.Inflater::new()
  let buf = @buffer.new()
  d.src(compressed)
  loop d.decode() {
    Await => {
      fail("unexpected Await")
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
  assert_eq(d.header().name, "test.txt")
  assert_eq(d.header().comment, "a comment")
  assert_eq(d.header().mod_time, 12345U)
}

///|
test "streaming gzip deflater with header" {
  let original = b"test"
  let header = @gzip.Header::{
    name: "out.txt",
    comment: "",
    extra: Bytes::default(),
    mod_time: 0U,
    os: b'\xFF',
  }
  let d = @gzip.Deflater::new(header~)
  let buf = @buffer.new()
  match d.encode(Some(original)) {
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
  let (decompressed, got_header) = @gzip.decompress(buf.to_bytes())
  assert_eq(decompressed, original)
  assert_eq(got_header.name, "out.txt")
}
