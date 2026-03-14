///|
test "round-trip: all sizes LSB 8" {
  let test_data : Array[Bytes] = [
    b"",
    b"a",
    b"Hello, World!",
    Bytes::makei(1000, fn(i) { (i % 256).to_byte() }),
    Bytes::makei(10000, fn(i) { (i % 256).to_byte() }),
  ]
  for data in test_data {
    let compressed = @lzw.compress(data, LSB, 8)
    let decompressed = @lzw.decompress(compressed, LSB, 8)
    inspect(decompressed == data, content="true")
  }
}

///|
test "round-trip: all sizes MSB 8" {
  let test_data : Array[Bytes] = [
    b"",
    b"a",
    b"Hello, World!",
    Bytes::makei(1000, fn(i) { (i % 256).to_byte() }),
    Bytes::makei(10000, fn(i) { (i % 256).to_byte() }),
  ]
  for data in test_data {
    let compressed = @lzw.compress(data, MSB, 8)
    let decompressed = @lzw.decompress(compressed, MSB, 8)
    inspect(decompressed == data, content="true")
  }
}

///|
test "round-trip: both bit orders agree on roundtrip" {
  let test_data : Array[Bytes] = [
    b"ABCABCABCABC",
    Bytes::makei(500, fn(i) { (i % 128).to_byte() }),
    Bytes::makei(5000, fn(i) { (i % 256).to_byte() }),
  ]
  for data in test_data {
    let c_lsb = @lzw.compress(data, LSB, 8)
    let c_msb = @lzw.compress(data, MSB, 8)
    let d_lsb = @lzw.decompress(c_lsb, LSB, 8)
    let d_msb = @lzw.decompress(c_msb, MSB, 8)
    inspect(d_lsb == data, content="true")
    inspect(d_msb == data, content="true")
  }
}

///|
test "round-trip: litWidth 2 to 8 LSB" {
  for lit_width in [2, 3, 4, 5, 6, 7, 8] {
    let max_val = 1 << lit_width
    let data = Bytes::makei(500, fn(i) { (i % max_val).to_byte() })
    let compressed = @lzw.compress(data, LSB, lit_width)
    let decompressed = @lzw.decompress(compressed, LSB, lit_width)
    inspect(decompressed == data, content="true")
  }
}

///|
test "round-trip: litWidth 2 to 8 MSB" {
  for lit_width in [2, 3, 4, 5, 6, 7, 8] {
    let max_val = 1 << lit_width
    let data = Bytes::makei(500, fn(i) { (i % max_val).to_byte() })
    let compressed = @lzw.compress(data, MSB, lit_width)
    let decompressed = @lzw.decompress(compressed, MSB, lit_width)
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
  let compressed = @lzw.compress(data, LSB, 8)
  let decompressed = @lzw.decompress(compressed, LSB, 8)
  inspect(decompressed == data, content="true")
  // Must actually compress
  inspect(compressed.length() < data.length(), content="true")
}

///|
test "round-trip: 32KB boundary" {
  let data = Bytes::makei(32768, fn(i) { (i % 256).to_byte() })
  for order in [@lzw.LSB, @lzw.MSB] {
    let compressed = @lzw.compress(data, order, 8)
    let decompressed = @lzw.decompress(compressed, order, 8)
    inspect(decompressed.length(), content="32768")
    inspect(decompressed == data, content="true")
  }
}

///|
test "round-trip: sizes around 32KB" {
  for size in [32000, 32700, 32767, 32768, 32769, 33000, 40000, 65536] {
    let data = Bytes::makei(size, fn(i) { (i % 256).to_byte() })
    let compressed = @lzw.compress(data, LSB, 8)
    let decompressed = @lzw.decompress(compressed, LSB, 8)
    if decompressed.length() != size {
      fail("size \{size}: got \{decompressed.length()}")
    }
  }
}

///|
test "round-trip: 100KB data" {
  let data = Bytes::makei(100000, fn(i) { (i % 256).to_byte() })
  let compressed = @lzw.compress(data, LSB, 8)
  let decompressed = @lzw.decompress(compressed, LSB, 8)
  inspect(decompressed.length(), content="100000")
  inspect(decompressed == data, content="true")
}

///|
test "signal protocol: chunked input LSB" {
  let data : Bytes = b"Hello, World!"
  let compressed = @lzw.compress(data, LSB, 8)
  let d = @lzw.Inflater::new(LSB, 8)
  let buf = @buffer.new()
  let mut pos = 0
  loop d.decode() {
    Await =>
      if pos >= compressed.length() {
        inspect(false, content="true")
      } else {
        d.src([compressed[pos]])
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

///|
test "signal protocol: chunked input MSB" {
  let data : Bytes = b"Hello, World!"
  let compressed = @lzw.compress(data, MSB, 8)
  let d = @lzw.Inflater::new(MSB, 8)
  let buf = @buffer.new()
  let mut pos = 0
  loop d.decode() {
    Await =>
      if pos >= compressed.length() {
        inspect(false, content="true")
      } else {
        d.src([compressed[pos]])
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

///|
test "signal protocol: chunked 1KB input" {
  let data = Bytes::makei(1024, fn(i) { (i % 256).to_byte() })
  let compressed = @lzw.compress(data, LSB, 8)
  let d = @lzw.Inflater::new(LSB, 8)
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
