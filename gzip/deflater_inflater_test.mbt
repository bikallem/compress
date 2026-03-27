///|
test "streaming gzip deflater round-trip" {
  let original = b"Hello, World! This is a test of gzip streaming."
  let d = @gzip.Deflater::new()
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
  let buf = @blit.Buffer::new()
  d.src(compressed[:])
  d.finish()
  loop d.decode() {
    Await => fail("unexpected Await with finished input")
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
test "streaming gzip inflater with chunked input" {
  let original = Bytes::makei(5000, fn(i) { (i % 251).to_byte() })
  let compressed = @gzip.compress(original)
  let d = @gzip.Inflater::new()
  let buf = @blit.Buffer::new()
  let chunk_size = 64
  let mut offset = 0
  let mut finished = false
  loop d.decode() {
    Await => {
      if offset >= compressed.length() {
        if finished {
          fail("unexpected Await after finish")
          break
        }
        finished = true
        d.finish()
        continue d.decode()
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
test "streaming gzip deflater + inflater round-trip" {
  let original = Bytes::makei(5000, fn(i) { (i % 251).to_byte() })
  // Compress with deflater
  let d = @gzip.Deflater::new()
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
  let inf = @gzip.Inflater::new()
  let dbuf = @blit.Buffer::new()
  inf.src(compressed[:])
  inf.finish()
  loop inf.decode() {
    Await => fail("unexpected Await with finished input")
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
  let buf = @blit.Buffer::new()
  d.src(compressed[:])
  d.finish()
  loop d.decode() {
    Await => fail("unexpected Await with finished input")
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
  let (decompressed, got_header) = @gzip.decompress(buf.to_bytes())
  assert_eq(decompressed, original)
  assert_eq(got_header.name, "out.txt")
}

///|
test "streaming gzip inflater handles dynamic header split" {
  let compressed : Bytes = b"\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\x03\xf3\x48\xcd\xc9\xc9\xd7\x51\x08\xcf\x2f\xca\x49\x51\x04\x00\xd0\xc3\x4a\xec\x0d\x00\x00\x00"
  let d = @gzip.Inflater::new()
  let buf = @blit.Buffer::new()
  d.src(compressed[:12])
  let mut fed_rest = false
  let mut finished = false
  loop d.decode() {
    Await =>
      if !fed_rest {
        fed_rest = true
        d.src(compressed[12:])
        continue d.decode()
      } else if !finished {
        finished = true
        d.finish()
        continue d.decode()
      } else {
        fail("unexpected Await after finish")
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
test "streaming gzip inflater preserves repeat state across byte chunks" {
  let compressed : Bytes = b"\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\xff\xed\xcc\xc1\x09\xc0\x20\x0c\x40\xd1\x7b\xa7\xc8\x04\xd9\x29\x85\xa0\x60\x35\x22\x29\x5d\xdf\x73\x0b\xdd\xe0\x5f\xdf\xe1\xd9\x35\xab\x49\x46\xf3\x21\x65\xc5\x3d\x25\x86\xab\x9c\x9e\x6f\xcd\x27\x54\x8a\xf5\xfe\xe1\xba\xdc\xf5\x30\x16\x16\x16\x16\x16\x16\x16\x16\x16\x16\x16\x16\x16\x16\x16\x16\x96\x9f\x65\x03\x40\x09\x48\xa4\x80\x11\x00\x00"
  let expected = dynamic_repeat_fixture_expected()
  let d = @gzip.Inflater::new()
  let buf = @blit.Buffer::new()
  let mut pos = 0
  let mut finished = false
  loop d.decode() {
    Await =>
      if pos >= compressed.length() {
        if finished {
          fail("unexpected Await after finish")
        } else {
          finished = true
          d.finish()
          continue d.decode()
        }
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

///|
test "streaming gzip inflater validates FHCRC across header chunks" {
  let original = b"header crc fixture"
  // Encoder now always writes FHCRC — use directly.
  let compressed = @gzip.compress(original)
  let d = @gzip.Inflater::new()
  let buf = @blit.Buffer::new()
  let mut pos = 0
  let mut finished = false
  loop d.decode() {
    Await =>
      if pos >= compressed.length() {
        if finished {
          fail("unexpected Await after finish")
        } else {
          finished = true
          d.finish()
          continue d.decode()
        }
      } else {
        let end = if pos + 3 > compressed.length() {
          compressed.length()
        } else {
          pos + 3
        }
        d.src(compressed[pos:end])
        pos = end
        continue d.decode()
      }
    Data(out) => {
      buf.write_bytesview(out)
      continue d.decode()
    }
    End => assert_eq(buf.to_bytes(), original)
    Error(e) => raise e
  }
}

///|
test "streaming gzip inflater consumes buffered concatenated members" {
  let first = @gzip.compress(
    b"first member",
    header=gzip_named_header("first.txt"),
  )
  let second = @gzip.compress(
    b"second member",
    header=gzip_named_header("second.txt"),
  )
  let d = @gzip.Inflater::new()
  let buf = @blit.Buffer::new()
  d.src((first + second)[:])
  d.finish()
  loop d.decode() {
    Await =>
      fail("unexpected Await with finished buffered concatenated members")
    Data(out) => {
      buf.write_bytesview(out)
      continue d.decode()
    }
    End => break
    Error(e) => raise e
  }
  assert_eq(buf.to_bytes(), b"first membersecond member")
  assert_eq(d.header().name, "second.txt")
  let headers = d.member_headers()
  assert_eq(headers.length(), 2)
  assert_eq(headers[0].name, "first.txt")
  assert_eq(headers[1].name, "second.txt")
}

///|
test "streaming gzip inflater chains concatenated members across exact boundary" {
  let first = @gzip.compress(b"first member")
  let second = @gzip.compress(b"second member")
  let d = @gzip.Inflater::new()
  let buf = @blit.Buffer::new()
  let mut fed_second = false
  let mut finished = false
  d.src(first[:])
  loop d.decode() {
    Await =>
      if !fed_second {
        fed_second = true
        d.src(second[:])
        continue d.decode()
      } else if !finished {
        finished = true
        d.finish()
        continue d.decode()
      } else {
        fail("unexpected Await after finish")
      }
    Data(out) => {
      buf.write_bytesview(out)
      continue d.decode()
    }
    End => break
    Error(e) => raise e
  }
  assert_eq(buf.to_bytes(), b"first membersecond member")
}
