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
        @flate.HuffmanOnly,
      ] {
      let compressed = @gzip.compress(data, level=lvl)
      let (decompressed, _) = @gzip.decompress(compressed)
      inspect(decompressed == data, content="true")
    }
  }
}

///|
test "round-trip: large repetitive data" {
  let buf = @blit.Buffer::new()
  for _ in 0..<500 {
    buf.write_bytes(b"ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
  }
  let data = buf.to_bytes()
  let compressed = @gzip.compress(data, level=@flate.BestCompression)
  let (decompressed, _) = @gzip.decompress(compressed)
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
    let compressed = @gzip.compress(data, level=lvl)
    let (decompressed, _) = @gzip.decompress(compressed)
    inspect(decompressed.length(), content="32768")
    inspect(decompressed == data, content="true")
  }
}

///|
test "round-trip: sizes around 32KB" {
  for size in [32000, 32700, 32767, 32768, 32769, 33000, 40000, 65536] {
    let data = Bytes::makei(size, fn(i) { (i % 256).to_byte() })
    let compressed = @gzip.compress(data)
    let (decompressed, _) = @gzip.decompress(compressed)
    if decompressed.length() != size {
      fail("size \{size}: got \{decompressed.length()}")
    }
  }
}

///|
test "round-trip: 100KB data" {
  let data = Bytes::makei(100000, fn(i) { (i % 256).to_byte() })
  let compressed = @gzip.compress(data)
  let (decompressed, _) = @gzip.decompress(compressed)
  inspect(decompressed.length(), content="100000")
  inspect(decompressed == data, content="true")
}

///|
test "round-trip: header preservation with all fields" {
  let data = Bytes::makei(1000, fn(i) { (i % 256).to_byte() })
  let header = @gzip.Header::{
    name: "testfile.bin",
    comment: "a test comment with unicode",
    extra: Bytes::makei(20, fn(i) { (i * 7 % 256).to_byte() }),
    mod_time: 1700000000U,
    os: b'\x03',
  }
  let compressed = @gzip.compress(data, header~)
  let (decompressed, got_header) = @gzip.decompress(compressed)
  inspect(decompressed == data, content="true")
  inspect(got_header.name, content="testfile.bin")
  inspect(got_header.comment, content="a test comment with unicode")
  inspect(got_header.extra == header.extra, content="true")
  inspect(got_header.mod_time, content="1700000000")
  inspect(got_header.os, content="b'\\x03'")
}

///|
test "round-trip: header preservation across compression levels" {
  let data = b"header level test data payload"
  let header = @gzip.Header::{
    name: "levels.txt",
    comment: "",
    extra: Bytes::default(),
    mod_time: 0U,
    os: b'\xFF',
  }
  for lvl in [@flate.NoCompression, @flate.BestSpeed, @flate.BestCompression] {
    let compressed = @gzip.compress(data, level=lvl, header~)
    let (decompressed, got_header) = @gzip.decompress(compressed)
    inspect(decompressed == data, content="true")
    inspect(got_header.name, content="levels.txt")
  }
}

///|
test "signal protocol: chunked input" {
  let data : Bytes = b"Hello, World!"
  let compressed = @gzip.compress(data)
  let d = @gzip.Inflater::new()
  let buf = @blit.Buffer::new()
  let mut pos = 0
  let mut finished = false
  loop d.decode() {
    Await =>
      if pos >= compressed.length() {
        if finished {
          inspect(false, content="true")
        } else {
          finished = true
          d.finish()
          continue d.decode()
        }
      } else {
        d.src([compressed[pos]])
        pos += 1
        continue d.decode()
      }
    Data(chunk) => {
      buf.write_bytesview(chunk)
      continue d.decode()
    }
    End => inspect(buf.to_bytes() == data, content="true")
    Error(e) => raise e
  }
}

///|
test "signal protocol: chunked input 1KB" {
  let data = Bytes::makei(1024, fn(i) { (i % 256).to_byte() })
  let compressed = @gzip.compress(data)
  let d = @gzip.Inflater::new()
  let buf = @blit.Buffer::new()
  let mut pos = 0
  let mut finished = false
  // Feed in 16-byte chunks
  loop d.decode() {
    Await =>
      if pos >= compressed.length() {
        if finished {
          inspect(false, content="true")
        } else {
          finished = true
          d.finish()
          continue d.decode()
        }
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
      buf.write_bytesview(chunk)
      continue d.decode()
    }
    End => inspect(buf.to_bytes() == data, content="true")
    Error(e) => raise e
  }
}
