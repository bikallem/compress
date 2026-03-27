///|
test "lz4 round-trip Hello" {
  let original : Bytes = b"Hello"
  let compressed = @lz4.compress(original)
  let decompressed = @lz4.decompress(compressed)
  assert_eq(decompressed, original)
}

///|
test "lz4 round-trip empty" {
  let original : Bytes = b""
  let compressed = @lz4.compress(original)
  let decompressed = @lz4.decompress(compressed)
  assert_eq(decompressed, original)
}

///|
test "lz4 round-trip repeated" {
  let original : Bytes = b"AAAAAAAAAA"
  let compressed = @lz4.compress(original)
  let decompressed = @lz4.decompress(compressed)
  assert_eq(decompressed, original)
}

///|
test "lz4 round-trip abcabc" {
  let original : Bytes = b"abcabcabcabc"
  let compressed = @lz4.compress(original)
  let decompressed = @lz4.decompress(compressed)
  assert_eq(decompressed, original)
}

///|
test "lz4 round-trip larger text" {
  let sb = @blit.Buffer::new(size_hint=500)
  for _ in 0..<10 {
    sb.write_bytes(b"The quick brown fox jumps over the lazy dog. ")
  }
  let original = sb.to_bytes()
  let compressed = @lz4.compress(original)
  let decompressed = @lz4.decompress(compressed)
  assert_eq(decompressed, original)
  // Repetitive data should compress
  inspect(compressed.length() < original.length(), content="true")
}

///|
test "lz4 round-trip binary data" {
  let original = Bytes::makei(256, fn(i) { i.to_byte() })
  let compressed = @lz4.compress(original)
  let decompressed = @lz4.decompress(compressed)
  assert_eq(decompressed, original)
}

///|
test "lz4 invalid magic" {
  let data : Bytes = [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
  let result = try? @lz4.decompress(data)
  guard result is Err(_) else { fail("expected error for invalid magic") }
}

///|
test "lz4 truncated data" {
  let data : Bytes = [0x04, 0x22, 0x4D, 0x18]
  let result = try? @lz4.decompress(data)
  guard result is Err(_) else { fail("expected error for truncated data") }
}

///|
test "lz4 single byte" {
  let original : Bytes = b"X"
  let compressed = @lz4.compress(original)
  let decompressed = @lz4.decompress(compressed)
  assert_eq(decompressed, original)
}

///|
test "lz4 frame header checksum" {
  // Compress, then corrupt the header checksum byte
  let original : Bytes = b"Hello, World!"
  let compressed = @lz4.compress(original)
  // The header checksum is the last byte before block data
  // For our frame: 4(magic) + 1(flg) + 1(bd) + 1(hc) = 7
  let corrupted = Bytes::makei(compressed.length(), fn(i) {
    if i == 6 {
      // corrupt header checksum
      (compressed[i].to_int() ^ 0xFF).to_byte()
    } else {
      compressed[i]
    }
  })
  let result = try? @lz4.decompress(corrupted)
  guard result is Err(_) else { fail("expected checksum mismatch error") }
}

///|
fn lz4_write_u32_le(buf : @blit.Buffer, value : UInt) -> Unit {
  buf.write_byte((value & 0xFFU).to_byte())
  buf.write_byte(((value >> 8) & 0xFFU).to_byte())
  buf.write_byte(((value >> 16) & 0xFFU).to_byte())
  buf.write_byte(((value >> 24) & 0xFFU).to_byte())
}

///|
fn lz4_test_read_u32_le(data : Bytes, pos : Int) -> UInt {
  data[pos].to_uint() |
  (data[pos + 1].to_uint() << 8) |
  (data[pos + 2].to_uint() << 16) |
  (data[pos + 3].to_uint() << 24)
}

///|
fn lz4_header_data_offset(data : Bytes) -> Int {
  let flg = data[4].to_int()
  let mut pos = 6
  if (flg & 0x08) != 0 {
    pos += 8
  }
  if (flg & 0x01) != 0 {
    pos += 4
  }
  pos + 1
}

///|
fn lz4_header_dict_id(data : Bytes) -> UInt {
  let flg = data[4].to_int()
  guard (flg & 0x01) != 0 else { return 0U }
  let mut pos = 6
  if (flg & 0x08) != 0 {
    pos += 8
  }
  lz4_test_read_u32_le(data, pos)
}

///|
fn lz4_block_header(data : Bytes, pos : Int) -> (Bool, Int) {
  let raw = lz4_test_read_u32_le(data, pos)
  ((raw & 0x80000000U) != 0U, (raw & 0x7FFFFFFFU).reinterpret_as_int())
}

///|
fn lz4_custom_frame(
  block_independence : Bool,
  block_checksum : Bool,
  dict_id : UInt,
  blocks : Array[Bytes],
  uncompressed : Array[Bool],
) -> Bytes {
  let out = @blit.Buffer::new()
  lz4_write_u32_le(out, 0x184D2204U)
  let flg = 0x40 |
    (if block_independence { 0x20 } else { 0 }) |
    (if block_checksum { 0x10 } else { 0 }) |
    (if dict_id != 0U { 0x01 } else { 0 })
  out.write_byte(flg.to_byte())
  out.write_byte((4 << 4).to_byte())
  if dict_id != 0U {
    lz4_write_u32_le(out, dict_id)
  }
  let header_bytes = out.to_bytes()
  let hc = (@checksum.xxh32(header_bytes[4:]) >> 8) & 0xFFU
  out.write_byte(hc.to_byte())
  for i in 0..<blocks.length() {
    let payload = blocks[i]
    let size = payload.length().reinterpret_as_uint()
    let header = if uncompressed[i] { size | 0x80000000U } else { size }
    lz4_write_u32_le(out, header)
    out.write_bytes(payload)
    if block_checksum {
      lz4_write_u32_le(out, @checksum.xxh32(payload[:]))
    }
  }
  lz4_write_u32_le(out, 0U)
  out.to_bytes()
}

///|
fn lz4_header_only_frame(flg : Int, bd : Int) -> Bytes {
  let out = @blit.Buffer::new()
  lz4_write_u32_le(out, 0x184D2204U)
  out.write_byte(flg.to_byte())
  out.write_byte(bd.to_byte())
  let header_bytes = out.to_bytes()
  let hc = (@checksum.xxh32(header_bytes[4:]) >> 8) & 0xFFU
  out.write_byte(hc.to_byte())
  lz4_write_u32_le(out, 0U)
  out.to_bytes()
}

///|
fn lz4_skippable_frame(tag : Int, payload : Bytes) -> Bytes {
  let out = @blit.Buffer::new()
  lz4_write_u32_le(out, 0x184D2A50U + tag.reinterpret_as_uint())
  lz4_write_u32_le(out, payload.length().reinterpret_as_uint())
  out.write_bytes(payload)
  out.to_bytes()
}

///|
test "lz4 decompresses dependent blocks" {
  let frame = lz4_custom_frame(false, false, 0U, [b"ABCD", b"\x00\x04\x00"], [
    true, false,
  ])
  let decompressed = @lz4.decompress(frame)
  assert_eq(decompressed, b"ABCDABCD")
}

///|
test "lz4 accepts frames with block checksums" {
  let frame = lz4_custom_frame(true, true, 0U, [b"checked block"], [true])
  let decompressed = @lz4.decompress(frame)
  assert_eq(decompressed, b"checked block")
}

///|
test "lz4 explicit dictionary metadata decodes dict-id frames" {
  let dict = b"external dictionary"
  let frame = lz4_custom_frame(
    false,
    false,
    0x12345678U,
    [b"dict-id payload"],
    [true],
  )
  let raw_result = try? @lz4.decompress(frame, dict~)
  match raw_result {
    Err(Lz4Error::InvalidHeader(msg)) =>
      assert_eq(msg, "dictionary id mismatch")
    Err(err) => fail("expected dictionary-id mismatch error, got \{err}")
    Ok(_) => fail("expected raw dictionary API to reject mismatched dict-id")
  }
  let decompressed = @lz4.decompress_with_dictionary(
    frame,
    @lz4.Dictionary::new(dict, dict_id=0x12345678U),
  )
  assert_eq(decompressed, b"dict-id payload")
}

///|
test "lz4 truncated dict id header" {
  let data : Bytes = b"\x04\x22\x4d\x18\x61\x40\x00"
  let result = try? @lz4.decompress(data)
  guard result is Err(_) else {
    fail("expected error for truncated dict-id header")
  }
}

///|
test "lz4 rejects reserved BD bits" {
  let frame = lz4_header_only_frame(0x60, 0x41)
  let result = try? @lz4.decompress(frame)
  match result {
    Err(Lz4Error::InvalidHeader(msg)) => assert_eq(msg, "reserved BD bits set")
    Err(err) => fail("expected reserved-BD error, got \{err}")
    Ok(_) => fail("expected error for reserved BD bits")
  }
}

///|
test "lz4 inflater validates explicit dictionary metadata" {
  let dict = b"external dictionary"
  let frame = lz4_custom_frame(
    false,
    false,
    0x12345678U,
    [b"dict-id payload"],
    [true],
  )
  let wrong = @lz4.Inflater::new(dict~)
  wrong.src(frame[:])
  wrong.finish()
  match wrong.decode() {
    Error(Lz4Error::InvalidHeader(msg)) =>
      assert_eq(msg, "dictionary id mismatch")
    other => fail("expected dictionary-id mismatch error, got \{other}")
  }
  let correct = @lz4.Inflater::new_with_dictionary(
    @lz4.Dictionary::new(dict, dict_id=0x12345678U),
  )
  let buf = @blit.Buffer::new()
  correct.src(frame[:])
  correct.finish()
  loop correct.decode() {
    Await => fail("expected full frame to decode without awaiting more input")
    Data(chunk) => {
      buf.write_bytesview(chunk)
      continue correct.decode()
    }
    End => break
    Error(e) => raise e
  }
  assert_eq(buf.to_bytes(), b"dict-id payload")
}

///|
test "lz4 inflater rejects reserved BD bits" {
  let frame = lz4_header_only_frame(0x60, 0x41)
  let d = @lz4.Inflater::new()
  d.src(frame[:])
  d.finish()
  match d.decode() {
    Error(Lz4Error::InvalidHeader(msg)) =>
      assert_eq(msg, "reserved BD bits set")
    other => fail("expected reserved-BD error, got \{other}")
  }
}

///|
test "lz4 missing end mark" {
  let compressed = @lz4.compress(b"Hello, World!")
  let truncated = Bytes::makei(compressed.length() - 8, fn(i) { compressed[i] })
  let result = try? @lz4.decompress(truncated)
  guard result is Err(_) else { fail("expected error for missing end mark") }
}

///|
test "lz4 decompress concatenated frames" {
  let combined = @lz4.compress(b"first frame") + @lz4.compress(b"second frame")
  let decompressed = @lz4.decompress(combined)
  assert_eq(decompressed, b"first framesecond frame")
}

///|
test "lz4 rejects trailing bytes after last frame" {
  let compressed = @lz4.compress(b"Hello, World!") + b"\x00"
  let result = try? @lz4.decompress(compressed)
  guard result is Err(_) else {
    fail("expected error for trailing bytes after last LZ4 frame")
  }
}

///|
test "lz4 decompress skips skippable frames" {
  let combined = lz4_skippable_frame(0, b"meta") +
    @lz4.compress(b"first") +
    lz4_skippable_frame(3, b"sidecar") +
    @lz4.compress(b"second")
  let decompressed = @lz4.decompress(combined)
  assert_eq(decompressed, b"firstsecond")
}

///|
test "lz4 rejects truncated skippable frames" {
  let frame = lz4_skippable_frame(1, b"metadata")
  let truncated = Bytes::makei(frame.length() - 2, fn(i) { frame[i] })
  let result = try? @lz4.decompress(truncated)
  guard result is Err(_) else {
    fail("expected error for truncated skippable frame")
  }
}

///|
test "lz4 compress uses external dictionaries" {
  let dict = b"shared dictionary block shared dictionary block shared dictionary block"
  let data = b"shared dictionary block shared dictionary block frame payload"
  let options : @lz4.FrameOptions = {
    block_independence: true,
    block_checksum: false,
    content_checksum: true,
    dict_id: 0U,
    block_max_size: Size64KB,
  }
  let compressed = @lz4.compress(data, dict~, options~)
  let without_dict = @lz4.compress(data, options~)
  assert_true(lz4_header_dict_id(compressed) != 0U)
  let result = try? @lz4.decompress(compressed)
  guard result is Err(_) else {
    fail("expected dictionary-backed frame to require a dictionary")
  }
  let decompressed = @lz4.decompress(compressed, dict~)
  assert_eq(decompressed, data)
  assert_true(compressed.length() < without_dict.length())
}

///|
test "lz4 compress emits configured frame flags" {
  let dict = b"external dictionary"
  let options : @lz4.FrameOptions = {
    block_independence: false,
    block_checksum: true,
    content_checksum: false,
    dict_id: 0x12345678U,
    block_max_size: Size256KB,
  }
  let original = b"configured frame"
  let compressed = @lz4.compress(original, dict~, options~)
  let flg = compressed[4].to_int()
  assert_true((flg & 0x20) == 0)
  assert_true((flg & 0x10) != 0)
  assert_true((flg & 0x08) != 0)
  assert_true((flg & 0x04) == 0)
  assert_true((flg & 0x01) != 0)
  let bd = (compressed[5].to_int() >> 4) & 0x07
  assert_eq(bd, 5)
  assert_eq(lz4_header_dict_id(compressed), 0x12345678U)
  let decompressed = @lz4.decompress_with_dictionary(
    compressed,
    @lz4.Dictionary::new(dict, dict_id=0x12345678U),
  )
  assert_eq(decompressed, original)
}

///|
test "lz4 deflater accepts frame options" {
  let dict = b"stream dictionary"
  let options : @lz4.FrameOptions = {
    block_independence: false,
    block_checksum: true,
    content_checksum: true,
    dict_id: 0x01020304U,
    block_max_size: Size256KB,
  }
  let original = b"streamed frame payload"
  let d = @lz4.Deflater::new_with_content_size(
    original.length(),
    dict~,
    options~,
  )
  let out = @blit.Buffer::new()
  match d.encode(Some(original[:])) {
    Data(chunk) => out.write_bytesview(chunk)
    Ok => fail("expected streaming lz4 output")
    End => fail("lz4 deflater should not end before finish")
    Error(e) => raise e
  }
  match d.encode(None) {
    Data(chunk) => out.write_bytesview(chunk)
    End => ()
    Ok => ()
    Error(e) => raise e
  }
  let compressed = out.to_bytes()
  let flg = compressed[4].to_int()
  assert_true((flg & 0x20) == 0)
  assert_true((flg & 0x10) != 0)
  assert_true((flg & 0x08) != 0)
  assert_true((flg & 0x04) != 0)
  assert_true((flg & 0x01) != 0)
  let bd = (compressed[5].to_int() >> 4) & 0x07
  assert_eq(bd, 5)
  assert_eq(lz4_header_dict_id(compressed), 0x01020304U)
  let decompressed = @lz4.decompress_with_dictionary(
    compressed,
    @lz4.Dictionary::new(dict, dict_id=0x01020304U),
  )
  assert_eq(decompressed, original)
}

///|
test "lz4 compress suppresses dict id without dictionary bytes" {
  let compressed = @lz4.compress(b"plain payload", options={
    block_independence: true,
    block_checksum: false,
    content_checksum: true,
    dict_id: 0x01020304U,
    block_max_size: Size64KB,
  })
  assert_eq(lz4_header_dict_id(compressed), 0U)
  let decompressed = @lz4.decompress(compressed)
  assert_eq(decompressed, b"plain payload")
}

///|
fn lz4_randomish_bytes(len : Int) -> Bytes {
  let out = @blit.Buffer::new(size_hint=len)
  let mut state = 0x12345678U
  for _ in 0..<len {
    state = state * 1664525U + 1013904223U
    out.write_byte(((state >> 24) & 0xFFU).to_byte())
  }
  out.to_bytes()
}

///|
test "lz4 dependent block encoding uses cross-block history" {
  let first = lz4_randomish_bytes(65536)
  let second_buf = @blit.Buffer::new(size_hint=65536)
  second_buf.write_bytesview(first[1:])
  second_buf.write_byte(first[65535])
  let data = first + second_buf.to_bytes()
  let independent = @lz4.compress(data)
  let dependent = @lz4.compress(data, options={
    block_independence: false,
    block_checksum: false,
    content_checksum: true,
    dict_id: 0U,
    block_max_size: Size64KB,
  })
  let independent_first_header = lz4_header_data_offset(independent)
  let (_, independent_first_size) = lz4_block_header(
    independent, independent_first_header,
  )
  let independent_second_header = independent_first_header +
    4 +
    independent_first_size
  let (independent_second_uncompressed, _) = lz4_block_header(
    independent, independent_second_header,
  )
  let first_header = lz4_header_data_offset(dependent)
  let (_, first_size) = lz4_block_header(dependent, first_header)
  let second_header = first_header + 4 + first_size
  let (second_uncompressed, second_size) = lz4_block_header(
    dependent, second_header,
  )
  assert_true(independent_second_uncompressed)
  assert_false(second_uncompressed)
  assert_true(second_size < 1024)
  let decompressed = @lz4.decompress(dependent)
  assert_eq(decompressed, data)
}

///|
test "lz4 deflater rejects declared content-size mismatch" {
  let d = @lz4.Deflater::new_with_content_size(3)
  match d.encode(Some(b"four"[:])) {
    Error(Lz4Error::CorruptData(msg)) =>
      assert_eq(msg, "lz4 input exceeds declared content size")
    other => fail("expected content-size mismatch error, got \{other}")
  }
}

///|
test "lz4 compress emits configured block max size" {
  let compressed = @lz4.compress(Bytes::make(70000, b'A'), options={
    block_independence: true,
    block_checksum: false,
    content_checksum: true,
    dict_id: 0U,
    block_max_size: Size256KB,
  })
  let bd = (compressed[5].to_int() >> 4) & 0x07
  assert_eq(bd, 5)
}
