///|
test "streaming zlib deflater round-trip" {
  let original = b"Hello, World! This is a test of zlib streaming."
  let d = @zlib.Deflater::new()
  let buf = @blit.Buffer::new()
  // Feed data
  match d.encode(Some(original[:])) {
    Data(out) => buf.write_bytesview(out)
    Ok | End | Error(_) => ()
  }
  // Finish
  loop d.encode(None) {
    Data(out) => {
      buf.write_bytesview(out)
      continue d.encode(None)
    }
    End => break
    Ok | Error(_) => {
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
  let buf = @blit.Buffer::new()
  // Feed all compressed data at once
  d.src(compressed[:])
  loop d.decode() {
    Await => {
      fail("unexpected Await with all data provided")
      break
    }
    Data(out) => {
      buf.write_bytesview(out)
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
  let cbuf = @blit.Buffer::new()
  match d.encode(Some(original[:])) {
    Data(out) => cbuf.write_bytesview(out)
    Ok | End | Error(_) => ()
  }
  loop d.encode(None) {
    Data(out) => {
      cbuf.write_bytesview(out)
      continue d.encode(None)
    }
    End => break
    Ok | Error(_) => {
      fail("unexpected signal")
      break
    }
  }
  let compressed = cbuf.to_bytes()
  // Decompress with inflater
  let inf = @zlib.Inflater::new()
  let dbuf = @blit.Buffer::new()
  inf.src(compressed[:])
  loop inf.decode() {
    Await => {
      fail("unexpected Await")
      break
    }
    Data(out) => {
      dbuf.write_bytesview(out)
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
  let buf = @blit.Buffer::new()
  match d.encode(Some(original[:])) {
    Data(out) => buf.write_bytesview(out)
    Ok | End | Error(_) => ()
  }
  loop d.encode(None) {
    Data(out) => {
      buf.write_bytesview(out)
      continue d.encode(None)
    }
    End => break
    Ok | Error(_) => {
      fail("unexpected signal")
      break
    }
  }
  let decompressed = @zlib.decompress(buf.to_bytes())
  assert_eq(decompressed, original)
}

///|
test "streaming zlib inflater handles dynamic header split" {
  let compressed : Bytes = b"\x78\x9c\xf3\x48\xcd\xc9\xc9\xd7\x51\x08\xcf\x2f\xca\x49\x51\x04\x00\x1f\x9e\x04\x6a"
  let d = @zlib.Inflater::new()
  let buf = @blit.Buffer::new()
  d.src(compressed[:4])
  let mut fed_rest = false
  loop d.decode() {
    Await =>
      if fed_rest {
        fail("unexpected Await after full input")
      } else {
        fed_rest = true
        d.src(compressed[4:])
        continue d.decode()
      }
    Data(out) => {
      buf.write_bytesview(out)
      continue d.decode()
    }
    End => assert_eq(buf.to_bytes(), b"Hello, World!")
    Error(e) => raise e
  }
}

///|
fn dynamic_repeat_fixture_expected() -> Bytes {
  let line = b"alpha token group one. beta token group two. gamma token group three.\n"
  let buf = @blit.Buffer::new()
  for _ in 0..<64 {
    buf.write_bytes(line)
  }
  buf.to_bytes()
}

///|
test "streaming zlib inflater preserves repeat state across byte chunks" {
  let compressed : Bytes = b"\x78\x9c\xed\xcc\xc1\x09\xc0\x20\x0c\x40\xd1\x7b\xa7\xc8\x04\xd9\x29\x85\xa0\x60\x35\x22\x29\x5d\xdf\x73\x0b\xdd\xe0\x5f\xdf\xe1\xd9\x35\xab\x49\x46\xf3\x21\x65\xc5\x3d\x25\x86\xab\x9c\x9e\x6f\xcd\x27\x54\x8a\xf5\xfe\xe1\xba\xdc\xf5\x30\x16\x16\x16\x16\x16\x16\x16\x16\x16\x16\x16\x16\x16\x16\x16\x16\x96\x9f\x65\x03\x2b\xae\x4e\x1b"
  let expected = dynamic_repeat_fixture_expected()
  let d = @zlib.Inflater::new()
  let buf = @blit.Buffer::new()
  let mut pos = 0
  loop d.decode() {
    Await =>
      if pos >= compressed.length() {
        fail("unexpected Await after full input")
      } else {
        d.src(compressed[pos:pos + 1])
        pos += 1
        continue d.decode()
      }
    Data(out) => {
      buf.write_bytesview(out)
      continue d.decode()
    }
    End => assert_eq(buf.to_bytes(), expected)
    Error(e) => raise e
  }
}
