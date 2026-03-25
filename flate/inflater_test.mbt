///|
test "inflate empty" {
  let compressed : Bytes = b"\x03\x00"
  let result = @flate.decompress(compressed)
  inspect(result.length(), content="0")
}

///|
test "inflate stored block" {
  let compressed : Bytes = b"\x01\x05\x00\xfa\xff\x48\x65\x6c\x6c\x6f"
  let result = @flate.decompress(compressed)
  let expected : Bytes = b"Hello"
  inspect(result == expected, content="true")
}

///|
test "inflate fixed huffman" {
  let compressed : Bytes = b"\xf3\x48\xcd\xc9\xc9\x07\x00"
  let result = @flate.decompress(compressed)
  let expected : Bytes = b"Hello"
  inspect(result == expected, content="true")
}

///|
test "inflate dynamic huffman" {
  let compressed : Bytes = b"\xf3\x48\xcd\xc9\xc9\xd7\x51\x08\xcf\x2f\xca\x49\x51\x04\x00"
  let result = @flate.decompress(compressed)
  let expected : Bytes = b"Hello, World!"
  inspect(result == expected, content="true")
}

///|
test "inflate corrupt input" {
  let result = try? @flate.decompress(b"\xFF\xFF")
  inspect(result is Err(_), content="true")
}

///|
test "inflate truncated input" {
  let result = try? @flate.decompress(b"\xf3\x48")
  inspect(result is Err(_), content="true")
}

///|
test "inflate invalid block type 3" {
  let result = try? @flate.decompress(b"\x07")
  inspect(result is Err(_), content="true")
}

///|
test "signal protocol - Await then Data then End" {
  // Feed data in two chunks to test Await behavior
  let compressed : Bytes = b"\x01\x05\x00\xfa\xff\x48\x65\x6c\x6c\x6f"
  let d = @flate.Inflater::new()
  // First decode without any input should return Await
  let signal1 = d.decode()
  inspect(signal1 is Await, content="true")
  // Feed first chunk (partial)
  d.src(Bytes::makei(5, fn(i) { compressed[i] })[:])
  // Should get Await again since stored block needs all bytes
  let mut got_await = false
  let mut got_data = false
  let buf = @blit.Buffer::new()
  // Drive to completion with both chunks
  loop d.decode() {
    Await => {
      got_await = true
      d.src(Bytes::makei(5, fn(i) { compressed[5 + i] })[:])
      continue d.decode()
    }
    Data(chunk) => {
      got_data = true
      buf.write_bytesview(chunk)
      continue d.decode()
    }
    End => {
      inspect(got_await, content="true")
      inspect(got_data, content="true")
      inspect(buf.to_bytes() == b"Hello", content="true")
    }
    Error(e) => raise e
  }
}

///|
fn streaming_decompress(compressed : Bytes, chunk_size : Int) -> (Int, Bool) {
  let inflater = @flate.Inflater::new()
  let mut total = 0
  let mut offset = 0
  let mut ok = true
  loop inflater.decode() {
    Await => {
      if offset >= compressed.length() {
        ok = false
        break
      }
      let end = if offset + chunk_size > compressed.length() {
        compressed.length()
      } else {
        offset + chunk_size
      }
      let chunk = Bytes::makei(end - offset, fn(i) { compressed[offset + i] })
      inflater.src(chunk[:])
      offset = end
      continue inflater.decode()
    }
    Data(chunk) => {
      total += chunk.length()
      continue inflater.decode()
    }
    End => ()
    Error(_) => ok = false
  }
  (total, ok)
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
test "streaming decompress with chunk boundaries on compressible data" {
  let pattern = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!@"
  let size = 256 * 1024
  let input = Bytes::makei(size, fn(i) {
    pattern[i % pattern.length()].to_int().to_byte()
  })
  let compressed = @flate.compress(input)
  for chunk_size in [32, 64, 128, 256, 512, 1024, 1580, 2048, 3160] {
    let (got, ok) = streaming_decompress(compressed, chunk_size)
    assert_true(ok)
    assert_eq(got, size)
  }
}

///|
test "inflate dynamic header split across chunks" {
  let compressed : Bytes = b"\xf3\x48\xcd\xc9\xc9\xd7\x51\x08\xcf\x2f\xca\x49\x51\x04\x00"
  let d = @flate.Inflater::new()
  let buf = @blit.Buffer::new()
  d.src(compressed[:2])
  let mut fed_rest = false
  loop d.decode() {
    Await =>
      if fed_rest {
        fail("unexpected Await after full input")
      } else {
        fed_rest = true
        d.src(compressed[2:])
        continue d.decode()
      }
    Data(chunk) => {
      buf.write_bytesview(chunk)
      continue d.decode()
    }
    End => assert_eq(buf.to_bytes(), b"Hello, World!")
    Error(e) => raise e
  }
}

///|
test "inflate dynamic repeat header across byte chunks" {
  let compressed : Bytes = b"\xed\xcc\xc1\x09\xc0\x20\x0c\x40\xd1\x7b\xa7\xc8\x04\xd9\x29\x85\xa0\x60\x35\x22\x29\x5d\xdf\x73\x0b\xdd\xe0\x5f\xdf\xe1\xd9\x35\xab\x49\x46\xf3\x21\x65\xc5\x3d\x25\x86\xab\x9c\x9e\x6f\xcd\x27\x54\x8a\xf5\xfe\xe1\xba\xdc\xf5\x30\x16\x16\x16\x16\x16\x16\x16\x16\x16\x16\x16\x16\x16\x16\x16\x16\x96\x9f\x65\x03"
  let expected = dynamic_repeat_fixture_expected()
  let d = @flate.Inflater::new()
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
    Data(chunk) => {
      buf.write_bytesview(chunk)
      continue d.decode()
    }
    End => assert_eq(buf.to_bytes(), expected)
    Error(e) => raise e
  }
}
