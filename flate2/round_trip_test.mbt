///|
test "cross-validate: flate2 decompress of flate-compressed data" {
  // These are known DEFLATE outputs from Go/flate
  // Empty fixed huffman block
  let empty_compressed : Bytes = b"\x03\x00"
  inspect(@flate2.decompress(empty_compressed).length(), content="0")
  // "Hello" stored block
  let stored : Bytes = b"\x01\x05\x00\xfa\xff\x48\x65\x6c\x6c\x6f"
  inspect(@flate2.decompress(stored) == b"Hello", content="true")
  // "Hello" fixed huffman
  let fixed : Bytes = b"\xf3\x48\xcd\xc9\xc9\x07\x00"
  inspect(@flate2.decompress(fixed) == b"Hello", content="true")
  // "Hello, World!" dynamic huffman
  let dynamic : Bytes = b"\xf3\x48\xcd\xc9\xc9\xd7\x51\x08\xcf\x2f\xca\x49\x51\x04\x00"
  inspect(@flate2.decompress(dynamic) == b"Hello, World!", content="true")
}

///|
test "round-trip: all compression levels" {
  let test_data : Array[Bytes] = [
    b"",
    b"a",
    b"Hello, World!",
    Bytes::makei(1000, fn(i) { (i % 256).to_byte() }),
    Bytes::makei(10000, fn(i) { (i % 26 + 65).to_byte() }),
  ]
  for data in test_data {
    for
      lvl in [
        @flate2.NoCompression,
        @flate2.BestSpeed,
        @flate2.Level(3),
        @flate2.DefaultCompression,
        @flate2.BestCompression,
      ] {
      let compressed = @flate2.compress(data, level=lvl)
      let decompressed = @flate2.decompress(compressed)
      inspect(decompressed == data, content="true")
    }
  }
}

///|
test "round-trip: large repetitive data" {
  let buf = @buffer.new()
  for _ in 0..<500 {
    buf.write_bytes(b"ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
  }
  let data = buf.to_bytes()
  let compressed = @flate2.compress(data, level=@flate2.BestCompression)
  let decompressed = @flate2.decompress(compressed)
  inspect(decompressed == data, content="true")
  // Must actually compress
  inspect(compressed.length() < data.length(), content="true")
}

///|
test "signal protocol: chunked input" {
  // Compress data, then decompress it by feeding one byte at a time
  let data : Bytes = b"Hello, World!"
  let compressed = @flate2.compress(data)
  let d = @flate2.Inflater::new()
  let buf = @buffer.new()
  let mut pos = 0
  loop d.decode() {
    Await =>
      if pos >= compressed.length() {
        // Should not happen for valid data
        inspect(false, content="true")
      } else {
        // Feed one byte at a time
        d.src(Bytes::makei(1, fn(_) { compressed[pos] }))
        pos += 1
        continue d.decode()
      }
    Data(chunk) => {
      buf.write_bytes(chunk)
      continue d.decode()
    }
    End => inspect(buf.to_bytes() == data, content="true")
    Error(e) => raise e
  }
}
