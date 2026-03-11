///|
test "inflate empty" {
  let compressed : Bytes = b"\x03\x00"
  let result = @flate2.decompress(compressed)
  inspect(result.length(), content="0")
}

///|
test "inflate stored block" {
  let compressed : Bytes = b"\x01\x05\x00\xfa\xff\x48\x65\x6c\x6c\x6f"
  let result = @flate2.decompress(compressed)
  let expected : Bytes = b"Hello"
  inspect(result == expected, content="true")
}

///|
test "inflate fixed huffman" {
  let compressed : Bytes = b"\xf3\x48\xcd\xc9\xc9\x07\x00"
  let result = @flate2.decompress(compressed)
  let expected : Bytes = b"Hello"
  inspect(result == expected, content="true")
}

///|
test "inflate dynamic huffman" {
  let compressed : Bytes = b"\xf3\x48\xcd\xc9\xc9\xd7\x51\x08\xcf\x2f\xca\x49\x51\x04\x00"
  let result = @flate2.decompress(compressed)
  let expected : Bytes = b"Hello, World!"
  inspect(result == expected, content="true")
}

///|
test "inflate corrupt input" {
  let result = try? @flate2.decompress(b"\xFF\xFF")
  inspect(result is Err(_), content="true")
}

///|
test "inflate truncated input" {
  let result = try? @flate2.decompress(b"\xf3\x48")
  inspect(result is Err(_), content="true")
}

///|
test "inflate invalid block type 3" {
  let result = try? @flate2.decompress(b"\x07")
  inspect(result is Err(_), content="true")
}

///|
test "signal protocol - Await then Data then End" {
  // Feed data in two chunks to test Await behavior
  let compressed : Bytes = b"\x01\x05\x00\xfa\xff\x48\x65\x6c\x6c\x6f"
  let d = @flate2.Inflater::new()
  // First decode without any input should return Await
  let signal1 = d.decode()
  inspect(signal1 is Await, content="true")
  // Feed first chunk (partial)
  d.src(Bytes::makei(5, fn(i) { compressed[i] }))
  // Should get Await again since stored block needs all bytes
  let mut got_await = false
  let mut got_data = false
  let buf = @buffer.new()
  // Drive to completion with both chunks
  loop d.decode() {
    Await => {
      got_await = true
      d.src(Bytes::makei(5, fn(i) { compressed[5 + i] }))
      continue d.decode()
    }
    Data(chunk) => {
      got_data = true
      buf.write_bytes(chunk)
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
