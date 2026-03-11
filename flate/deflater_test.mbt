///|
test "compress empty" {
  let result = @flate.compress(b"")
  // Should round-trip
  let decompressed = @flate.decompress(result)
  inspect(decompressed.length(), content="0")
}

///|
test "compress hello" {
  let data : Bytes = b"Hello, World!"
  let compressed = @flate.compress(data)
  let decompressed = @flate.decompress(compressed)
  inspect(decompressed == data, content="true")
}

///|
test "compress levels" {
  let data : Bytes = b"Hello, World! Hello, World! Hello, World!"
  for
    lvl in [
      @flate.NoCompression,
      @flate.BestSpeed,
      @flate.Level(2),
      @flate.Level(3),
      @flate.Level(4),
      @flate.DefaultCompression,
      @flate.BestCompression,
    ] {
    let compressed = @flate.compress(data, level=lvl)
    let decompressed = @flate.decompress(compressed)
    inspect(decompressed == data, content="true")
  }
}

///|
test "encode signal protocol" {
  let data : Bytes = b"Hello"
  let e = @flate.Deflater::new()
  let buf = @buffer.new()
  // Feed data
  let s1 = e.encode(Some(data))
  inspect(s1 is Ok, content="true")
  // Signal EOF
  loop e.encode(None) {
    Ok | End => ()
    Data(chunk) => {
      buf.write_bytes(chunk)
      continue e.encode(None)
    }
    Error(e) => raise e
  }
  // Verify round-trip
  let compressed = buf.to_bytes()
  let decompressed = @flate.decompress(compressed)
  inspect(decompressed == data, content="true")
}

///|
test "round-trip repetitive data" {
  // Build repetitive data that exercises LZ77 matching
  let buf = @buffer.new()
  for _ in 0..<100 {
    buf.write_bytes(b"The quick brown fox jumps over the lazy dog. ")
  }
  let data = buf.to_bytes()
  let compressed = @flate.compress(data)
  let decompressed = @flate.decompress(compressed)
  inspect(decompressed == data, content="true")
  // Should actually compress
  inspect(compressed.length() < data.length(), content="true")
}
