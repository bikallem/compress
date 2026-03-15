///|
test "cross-validate: flate2 decompress of flate-compressed data" {
  // These are known DEFLATE outputs from Go/flate
  // Empty fixed huffman block
  let empty_compressed : Bytes = b"\x03\x00"
  inspect(@flate.decompress(empty_compressed).length(), content="0")
  // "Hello" stored block
  let stored : Bytes = b"\x01\x05\x00\xfa\xff\x48\x65\x6c\x6c\x6f"
  inspect(@flate.decompress(stored) == b"Hello", content="true")
  // "Hello" fixed huffman
  let fixed : Bytes = b"\xf3\x48\xcd\xc9\xc9\x07\x00"
  inspect(@flate.decompress(fixed) == b"Hello", content="true")
  // "Hello, World!" dynamic huffman
  let dynamic : Bytes = b"\xf3\x48\xcd\xc9\xc9\xd7\x51\x08\xcf\x2f\xca\x49\x51\x04\x00"
  inspect(@flate.decompress(dynamic) == b"Hello, World!", content="true")
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
        @flate.NoCompression,
        @flate.BestSpeed,
        @flate.Level(3),
        @flate.DefaultCompression,
        @flate.BestCompression,
      ] {
      let compressed = @flate.compress(data, level=lvl)
      let decompressed = @flate.decompress(compressed)
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
  let compressed = @flate.compress(data, level=@flate.BestCompression)
  let decompressed = @flate.decompress(compressed)
  inspect(decompressed == data, content="true")
  // Must actually compress
  inspect(compressed.length() < data.length(), content="true")
}

///|
test "round-trip: 32KB boundary all levels" {
  let data = Bytes::makei(32768, fn(i) { (i % 256).to_byte() })
  for
    lvl in [
      @flate.NoCompression,
      @flate.BestSpeed,
      @flate.Level(3),
      @flate.DefaultCompression,
      @flate.BestCompression,
    ] {
    let compressed = @flate.compress(data, level=lvl)
    let decompressed = @flate.decompress(compressed)
    inspect(decompressed.length(), content="32768")
    inspect(decompressed == data, content="true")
  }
}

///|
test "round-trip: sizes around 32KB" {
  for size in [32000, 32700, 32767, 32768, 32769, 33000, 40000, 65536] {
    let data = Bytes::makei(size, fn(i) { (i % 256).to_byte() })
    let compressed = @flate.compress(data)
    let decompressed = @flate.decompress(compressed)
    if decompressed.length() != size {
      fail("size \{size}: got \{decompressed.length()}")
    }
  }
}

///|
test "signal protocol: chunked input" {
  // Compress data, then decompress it by feeding one byte at a time
  let data : Bytes = b"Hello, World!"
  let compressed = @flate.compress(data)
  let d = @flate.Inflater::new()
  let buf = @buffer.new()
  let mut pos = 0
  loop d.decode() {
    Await =>
      if pos >= compressed.length() {
        // Should not happen for valid data
        inspect(false, content="true")
      } else {
        // Feed one byte at a time
        d.src(compressed[pos:pos + 1])
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
