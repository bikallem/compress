///|
test "round-trip: small data" {
  let test_data : Array[Bytes] = [
    b"a",
    b"Hello, World!",
    b"The quick brown fox jumps over the lazy dog.",
    Bytes::makei(100, fn(i) { (i % 256).to_byte() }),
  ]
  for data in test_data {
    let compressed = @bzip2.compress(data)
    let decompressed = @bzip2.decompress(compressed)
    inspect(decompressed == data, content="true")
  }
}

///|
test "round-trip: 1KB data" {
  let data = Bytes::makei(1024, fn(i) { (i % 256).to_byte() })
  let compressed = @bzip2.compress(data)
  let decompressed = @bzip2.decompress(compressed)
  inspect(decompressed.length(), content="1024")
  inspect(decompressed == data, content="true")
}

///|
test "round-trip: 10KB data" {
  let data = Bytes::makei(10000, fn(i) { (i % 256).to_byte() })
  let compressed = @bzip2.compress(data)
  let decompressed = @bzip2.decompress(compressed)
  inspect(decompressed.length(), content="10000")
  inspect(decompressed == data, content="true")
}

///|
test "round-trip: 100KB data" {
  let data = Bytes::makei(100000, fn(i) { (i % 256).to_byte() })
  let compressed = @bzip2.compress(data)
  let decompressed = @bzip2.decompress(compressed)
  inspect(decompressed.length(), content="100000")
  inspect(decompressed == data, content="true")
}

///|
test "round-trip: all compression levels" {
  let data = Bytes::makei(5000, fn(i) { (i % 26 + 65).to_byte() })
  for level in [1, 2, 3, 4, 5, 6, 7, 8, 9] {
    let compressed = @bzip2.compress(data, level~)
    let decompressed = @bzip2.decompress(compressed)
    inspect(decompressed == data, content="true")
  }
}

///|
test "round-trip: large repetitive data" {
  let buf = @buffer.new()
  for _ in 0..<500 {
    buf.write_bytes(b"ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
  }
  let data = buf.to_bytes()
  let compressed = @bzip2.compress(data)
  let decompressed = @bzip2.decompress(compressed)
  inspect(decompressed == data, content="true")
  // Must actually compress
  inspect(compressed.length() < data.length(), content="true")
}

///|
test "round-trip: all zeros" {
  let data = Bytes::make(10000, b'\x00')
  let compressed = @bzip2.compress(data)
  let decompressed = @bzip2.decompress(compressed)
  inspect(decompressed == data, content="true")
  // Highly compressible
  inspect(compressed.length() < data.length(), content="true")
}

///|
test "round-trip: all 0xFF" {
  let data = Bytes::make(10000, b'\xFF')
  let compressed = @bzip2.compress(data)
  let decompressed = @bzip2.decompress(compressed)
  inspect(decompressed == data, content="true")
}

///|
test "round-trip: RLE1 heavy data" {
  // Long runs of the same byte to exercise RLE1 encoding
  let buf = @buffer.new()
  for b_val in [b'\x00', b'\x41', b'\xFF'] {
    for _ in 0..<300 {
      buf.write_byte(b_val)
    }
  }
  let data = buf.to_bytes()
  let compressed = @bzip2.compress(data)
  let decompressed = @bzip2.decompress(compressed)
  inspect(decompressed == data, content="true")
}

///|
test "round-trip: all byte values" {
  let data = Bytes::makei(256, fn(i) { i.to_byte() })
  let compressed = @bzip2.compress(data)
  let decompressed = @bzip2.decompress(compressed)
  inspect(decompressed == data, content="true")
}

///|
test "round-trip: level 1 vs level 9 both correct" {
  let data = Bytes::makei(10000, fn(i) { (i % 26 + 97).to_byte() })
  let c1 = @bzip2.compress(data, level=1)
  let c9 = @bzip2.compress(data, level=9)
  let d1 = @bzip2.decompress(c1)
  let d9 = @bzip2.decompress(c9)
  inspect(d1 == data, content="true")
  inspect(d9 == data, content="true")
}

///|
test "signal protocol: chunked input" {
  let data = Bytes::makei(1024, fn(i) { (i % 256).to_byte() })
  let compressed = @bzip2.compress(data)
  let d = @bzip2.Inflater::new()
  let buf = @buffer.new()
  let mut pos = 0
  // Feed in 16-byte chunks
  loop d.decode() {
    Await =>
      if pos >= compressed.length() {
        inspect(false, content="true")
      } else {
        let end = if pos + 16 > compressed.length() {
          compressed.length()
        } else {
          pos + 16
        }
        let chunk = Bytes::makei(end - pos, fn(i) { compressed[pos + i] })
        d.src(chunk)
        pos = end
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
