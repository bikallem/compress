///|
test "round-trip: small data" {
  let test_data : Array[Bytes] = [
    b"a",
    b"Hello, World!",
    b"The quick brown fox jumps over the lazy dog.",
    Bytes::makei(100, fn(i) { (i % 256).to_byte() }),
  ]
  for data in test_data {
    let compressed = @zstd.compress(data)
    let decompressed = @zstd.decompress(compressed)
    inspect(decompressed == data, content="true")
  }
}

///|
test "round-trip: 1KB data" {
  let data = Bytes::makei(1024, fn(i) { (i % 256).to_byte() })
  let compressed = @zstd.compress(data)
  let decompressed = @zstd.decompress(compressed)
  inspect(decompressed.length(), content="1024")
  inspect(decompressed == data, content="true")
}

///|
test "round-trip: 10KB data" {
  let data = Bytes::makei(10000, fn(i) { (i % 256).to_byte() })
  let compressed = @zstd.compress(data)
  let decompressed = @zstd.decompress(compressed)
  inspect(decompressed.length(), content="10000")
  inspect(decompressed == data, content="true")
}

///|
test "round-trip: 100KB data" {
  let data = Bytes::makei(100000, fn(i) { (i % 256).to_byte() })
  let compressed = @zstd.compress(data)
  let decompressed = @zstd.decompress(compressed)
  inspect(decompressed.length(), content="100000")
  inspect(decompressed == data, content="true")
}

///|
test "round-trip: large repetitive data" {
  let buf = @blit.Buffer::new()
  for _ in 0..<500 {
    buf.write_bytes(b"ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
  }
  let data = buf.to_bytes()
  let compressed = @zstd.compress(data)
  let decompressed = @zstd.decompress(compressed)
  inspect(decompressed == data, content="true")
  // Compressed blocks should achieve meaningful compression on repetitive data
  inspect(compressed.length() < data.length(), content="true")
}

///|
test "round-trip: ascii-biased text" {
  let buf = @blit.Buffer::new()
  for i in 0..<256 {
    buf.write_bytes(
      @utf8.encode(
        "log level=info service=api shard=\{i % 7} user=user\{i % 19} region=eu-west-1 action=read path=/v1/item/\{i % 23}\n"[:],
      ),
    )
  }
  let data = buf.to_bytes()
  let compressed = @zstd.compress(data)
  let decompressed = @zstd.decompress(compressed)
  assert_eq(decompressed, data)
  assert_true(compressed.length() < data.length())
}

///|
test "round-trip: all zeros 1KB" {
  let data = Bytes::make(1024, b'\x00')
  let compressed = @zstd.compress(data)
  let decompressed = @zstd.decompress(compressed)
  inspect(decompressed == data, content="true")
  inspect(compressed.length() < data.length(), content="true")
}

///|
test "round-trip: all byte values" {
  let data = Bytes::makei(256, fn(i) { i.to_byte() })
  let compressed = @zstd.compress(data)
  let decompressed = @zstd.decompress(compressed)
  inspect(decompressed == data, content="true")
}

///|
test "round-trip: 1MB repeating text" {
  let pattern = "The quick brown fox jumps over the lazy dog. "
  let pattern_bytes = @utf8.encode(pattern[:])
  let plen = pattern_bytes.length()
  let buf = @blit.Buffer::new()
  let mut written = 0
  while written + plen <= 1048576 {
    buf.write_bytes(pattern_bytes)
    written += plen
  }
  let remaining = 1048576 - written
  for i in 0..<remaining {
    buf.write_byte(pattern_bytes[i])
  }
  let data = buf.to_bytes()
  let compressed = @zstd.compress(data)
  let decompressed = @zstd.decompress(compressed)
  assert_eq(data.length(), decompressed.length())
  assert_eq(data, decompressed)
  // Should compress very well
  assert_true(compressed.length() < 300)
}

///|
test "signal protocol: chunked input" {
  let data = Bytes::makei(1024, fn(i) { (i % 256).to_byte() })
  let compressed = @zstd.compress(data)
  let d = @zstd.Inflater::new()
  let buf = @blit.Buffer::new()
  let chunk_size = 11
  let mut pos = 0
  loop d.decode() {
    Await =>
      if pos >= compressed.length() {
        inspect(false, content="true")
        break
      } else {
        let end = if pos + chunk_size > compressed.length() {
          compressed.length()
        } else {
          pos + chunk_size
        }
        let chunk = Bytes::makei(end - pos, fn(i) { compressed[pos + i] })
        d.src(chunk[:])
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

///|
test "signal protocol: deflater streaming" {
  let data = Bytes::makei(1024, fn(i) { (i % 256).to_byte() })
  let d = @zstd.Deflater::new()
  match d.encode(Some(data[:512])) {
    Ok => ()
    Data(_) | End => ()
    Error(e) => raise e
  }
  match d.encode(Some(data[512:])) {
    Ok => ()
    Data(_) | End => ()
    Error(e) => raise e
  }
  let buf = @blit.Buffer::new()
  match d.encode(None) {
    Data(out) => buf.write_bytesview(out)
    End => ()
    Ok => ()
    Error(e) => raise e
  }
  let compressed = buf.to_bytes()
  let decompressed = @zstd.decompress(compressed)
  assert_eq(decompressed, data)
}

///|
fn raw_dict_fixture() -> Bytes {
  b"alpha token group one. beta token group two. gamma token group three. raw dictionary fixture."
}

///|
test "round-trip: with raw dictionary" {
  let dict = raw_dict_fixture()
  let data = dict + b" tail bytes that do not appear in the dictionary."
  let compressed_no_dict = @zstd.compress(data)
  let compressed_with_dict = @zstd.compress(data, dict~)
  let decompressed = @zstd.decompress(compressed_with_dict, dict~)
  assert_eq(decompressed, data)
  assert_true(compressed_with_dict.length() < compressed_no_dict.length())
  let missing_dict = try? @zstd.decompress(compressed_with_dict)
  match missing_dict {
    Err(_) => ()
    Ok(_) => fail("expected dictionary-backed frame to require the dictionary")
  }
}

///|
test "round-trip: with short raw dictionary" {
  let dict = b"abc"
  let data = b"abcabcabcabcxyzabcabc"
  let compressed = @zstd.compress(data, dict~)
  let decompressed = @zstd.decompress(compressed, dict~)
  assert_eq(decompressed, data)
  let d = @zstd.Inflater::new(dict~)
  let buf = @blit.Buffer::new()
  d.src(compressed[:])
  loop d.decode() {
    Await => fail("unexpected Await with full input")
    Data(chunk) => {
      buf.write_bytesview(chunk)
      continue d.decode()
    }
    End => break
    Error(e) => raise e
  }
  assert_eq(buf.to_bytes(), data)
}

///|
test "round-trip: with short raw dictionary using zstd magic prefix" {
  let dict = b"\x37\xa4\x30\xecxy"
  let data = dict + dict + b" trailing payload"
  let compressed = @zstd.compress(data, dict~)
  let decompressed = @zstd.decompress(compressed, dict~)
  assert_eq(decompressed, data)
}

///|
test "round-trip: malformed formatted dictionary is rejected on encode" {
  let valid = formatted_dict_fixture()
  let dict = Bytes::makei(32, fn(i) { valid[i] })
  let result = try? @zstd.compress(b"raw fallback payload", dict~)
  match result {
    Err(_) => ()
    Ok(_) => fail("expected malformed formatted dictionary to be rejected")
  }
}

///|
test "signal protocol: malformed formatted dictionary is rejected at deflater construction" {
  let valid = formatted_dict_fixture()
  let dict = Bytes::makei(32, fn(i) { valid[i] })
  let result = try? @zstd.Deflater::new(dict~)
  match result {
    Err(_) => ()
    Ok(_) => fail("expected malformed formatted dictionary to be rejected")
  }
}

///|
test "zstd formatted frame rejects malformed fallback dictionary" {
  let valid = formatted_dict_fixture()
  let malformed = Bytes::makei(32, fn(i) { valid[i] })
  let compressed = @zstd.compress(formatted_dict_fixture_input(), dict=valid)
  let result = try? @zstd.decompress(compressed, dict=malformed)
  guard result is Err(_) else {
    fail(
      "expected formatted dictionary frame to reject malformed fallback dictionary",
    )
  }
}

///|
test "signal protocol: inflater emits before checksum" {
  let data = Bytes::makei(4096, fn(i) { (i * 17 % 251).to_byte() })
  let compressed = @zstd.compress(data)
  let d = @zstd.Inflater::new()
  let buf = @blit.Buffer::new()
  d.src(compressed[:compressed.length() - 4])
  let mut saw_data = false
  loop d.decode() {
    Await => break
    Data(chunk) => {
      saw_data = true
      buf.write_bytesview(chunk)
      continue d.decode()
    }
    End => fail("expected checksum bytes to still be outstanding")
    Error(e) => raise e
  }
  assert_true(saw_data)
  d.src(compressed[compressed.length() - 4:])
  loop d.decode() {
    Await => fail("expected checksum completion after trailer")
    Data(chunk) => {
      buf.write_bytesview(chunk)
      continue d.decode()
    }
    End => break
    Error(e) => raise e
  }
  assert_eq(buf.to_bytes(), data)
}

///|
test "round-trip: fast mode still compresses repeated data" {
  let buf = @blit.Buffer::new()
  for _ in 0..<256 {
    buf.write_bytes(b"fast mode repeated payload ")
  }
  let data = buf.to_bytes()
  let compressed = @zstd.compress(data, level=Fast)
  let decompressed = @zstd.decompress(compressed)
  assert_eq(decompressed, data)
  assert_true(compressed.length() < data.length())
}

///|
test "signal protocol: deflater emits before finish on full block" {
  let full_block = 131072
  let data = Bytes::makei(full_block + 4096, fn(i) { (i * 11 % 251).to_byte() })
  let d = @zstd.Deflater::new()
  let out = @blit.Buffer::new()
  match d.encode(Some(data[:full_block])) {
    Data(chunk) => {
      assert_true(chunk.length() > 0)
      out.write_bytesview(chunk)
    }
    Ok =>
      fail("expected compressed output once a full zstd block was available")
    End => fail("unexpected end")
    Error(e) => raise e
  }
  match d.encode(Some(data[full_block:])) {
    Data(chunk) => out.write_bytesview(chunk)
    Ok | End => ()
    Error(e) => raise e
  }
  match d.encode(None) {
    Data(chunk) => out.write_bytesview(chunk)
    Ok | End => ()
    Error(e) => raise e
  }
  let compressed = out.to_bytes()
  let decompressed = @zstd.decompress(compressed)
  assert_eq(decompressed, data)
}

///|
fn zstd_level_fixture() -> Bytes {
  let buf = @blit.Buffer::new()
  for _ in 0..<128 {
    buf.write_bytes(b"aaaaabaaaaacaaaaadaaaaefaaaaabaaaaacaaaaadaaaaef")
    buf.write_bytes(b"token-1 route=/v1/item/123 status=200 cluster=alpha ")
    buf.write_bytes(b"aaaaabaaaaacaaaaadaaaaefaaaaabaaaaacaaaaadaaaaeg")
  }
  buf.to_bytes()
}

///|
fn zstd_search_depth_fixture() -> Bytes {
  let long = b"ABCDabcdefghijklmnopqrstuvwxyz0123456789"
  let short = b"ABCDzzzz"
  let buf = @blit.Buffer::new()
  for i in 0..<96 {
    buf.write_bytes(long)
    buf.write_byte((i % 251).to_byte())
    buf.write_bytes(b"--")
    buf.write_bytes(short)
    buf.write_byte((i * 17 % 251).to_byte())
    buf.write_bytes(b"++")
    buf.write_bytes(long)
    buf.write_byte((i % 13).to_byte())
    buf.write_bytes(b"\n")
  }
  buf.to_bytes()
}

///|
test "compression levels change zstd one-shot output" {
  let data = zstd_level_fixture()
  let fast = @zstd.compress(data, level=Fast)
  let best = @zstd.compress(data, level=Best)
  assert_eq(@zstd.decompress(fast), data)
  assert_eq(@zstd.decompress(best), data)
  assert_true(best.length() <= fast.length())
}

///|
test "signal protocol: zstd deflater honors compression level" {
  let data = zstd_level_fixture()
  let fast = @zstd.Deflater::new(level=Fast)
  let best = @zstd.Deflater::new(level=Best)
  let fast_buf = @blit.Buffer::new()
  let best_buf = @blit.Buffer::new()
  match fast.encode(Some(data[:])) {
    Data(out) => fast_buf.write_bytesview(out)
    Ok | End => ()
    Error(e) => raise e
  }
  loop fast.encode(None) {
    Data(out) => {
      fast_buf.write_bytesview(out)
      continue fast.encode(None)
    }
    End => break
    Ok => ()
    Error(e) => raise e
  }
  match best.encode(Some(data[:])) {
    Data(out) => best_buf.write_bytesview(out)
    Ok | End => ()
    Error(e) => raise e
  }
  loop best.encode(None) {
    Data(out) => {
      best_buf.write_bytesview(out)
      continue best.encode(None)
    }
    End => break
    Ok => ()
    Error(e) => raise e
  }
  let fast_out = fast_buf.to_bytes()
  let best_out = best_buf.to_bytes()
  assert_eq(@zstd.decompress(fast_out), data)
  assert_eq(@zstd.decompress(best_out), data)
  assert_true(best_out.length() <= fast_out.length())
}

///|
test "higher zstd levels search deeper hash history" {
  let data = zstd_search_depth_fixture()
  let fast = @zstd.compress(data, level=Fast)
  let best = @zstd.compress(data, level=Best)
  assert_eq(@zstd.decompress(fast), data)
  assert_eq(@zstd.decompress(best), data)
  assert_true(best.length() < fast.length())
}
