///|
test "brotli round-trip Hello" {
  let original : Bytes = b"Hello"
  let compressed = @brotli.compress(original)
  let decompressed = @brotli.decompress(compressed)
  assert_eq(decompressed, original)
}

///|
test "brotli round-trip empty" {
  let original : Bytes = b""
  let compressed = @brotli.compress(original)
  let decompressed = @brotli.decompress(compressed)
  assert_eq(decompressed, original)
}

///|
test "brotli round-trip repeated" {
  let original : Bytes = b"AAAAAAAAAA"
  let compressed = @brotli.compress(original)
  let decompressed = @brotli.decompress(compressed)
  assert_eq(decompressed, original)
}

///|
test "brotli round-trip larger text" {
  let sb = @blit.Buffer::new(size_hint=500)
  for _ in 0..<10 {
    sb.write_bytes(b"The quick brown fox jumps over the lazy dog. ")
  }
  let original = sb.to_bytes()
  let compressed = @brotli.compress(original)
  let decompressed = @brotli.decompress(compressed)
  assert_eq(decompressed, original)
}

///|
test "brotli round-trip binary data" {
  let original = Bytes::makei(256, fn(i) { i.to_byte() })
  let compressed = @brotli.compress(original)
  let decompressed = @brotli.decompress(compressed)
  assert_eq(decompressed, original)
}

///|
test "brotli single byte" {
  let original : Bytes = b"X"
  let compressed = @brotli.compress(original)
  let decompressed = @brotli.decompress(compressed)
  assert_eq(decompressed, original)
}

///|
test "brotli all zeros" {
  let original = Bytes::make(1000, b'\x00')
  let compressed = @brotli.compress(original)
  let decompressed = @brotli.decompress(compressed)
  assert_eq(decompressed, original)
}

///|
test "brotli all 0xFF" {
  let original = Bytes::make(1000, b'\xFF')
  let compressed = @brotli.compress(original)
  let decompressed = @brotli.decompress(compressed)
  assert_eq(decompressed, original)
}

///|
test "brotli level 0 (no compression)" {
  let original : Bytes = b"Hello, level 0!"
  let compressed = @brotli.compress(original, level=Level(0))
  let decompressed = @brotli.decompress(compressed)
  assert_eq(decompressed, original)
}

///|
test "brotli default level" {
  let original : Bytes = b"Hello, default level!"
  let compressed = @brotli.compress(original, level=Default)
  let decompressed = @brotli.decompress(compressed)
  assert_eq(decompressed, original)
}

///|
test "brotli best level" {
  let original : Bytes = b"Hello, best level!"
  let compressed = @brotli.compress(original, level=Best)
  let decompressed = @brotli.decompress(compressed)
  assert_eq(decompressed, original)
}

///|
/// Test decoding Go-compressed brotli that uses the static dictionary.
/// "function return value" compressed by Go brotli at level 6.
test "brotli decode Go-compressed with dictionary (small)" {
  let compressed = hex_to_bytes("1b14000024007290420e298b1bf40401")
  let expected : Bytes = b"function return value"
  let decompressed = @brotli.decompress(compressed)
  assert_eq(decompressed, expected)
}

///|
test "brotli rejects invalid dictionary transform" {
  // Mutated from the valid small dictionary fixture above.
  let compressed = hex_to_bytes("1b14000824007290420e298b1bf40401")
  let result = try? @brotli.decompress(compressed)
  match result {
    Err(BrotliError::CorruptData(msg)) =>
      assert_eq(msg, "invalid dictionary transform")
    Err(BrotliError::UnexpectedEOF) => ()
    Err(err) => fail("expected a corrupt-stream error, got \{err}")
    Ok(_) => fail("expected error for invalid dictionary transform")
  }
}

///|
test "brotli rejects truncated stream that previously hung" {
  // Another mutation of the valid small dictionary fixture. Before the fix this
  // could loop indefinitely instead of failing closed.
  let compressed = hex_to_bytes("0b14000024007290420e298b1bf40401")
  let result = try? @brotli.decompress(compressed)
  match result {
    Err(BrotliError::UnexpectedEOF) => ()
    Err(err) => fail("expected UnexpectedEOF, got \{err}")
    Ok(_) => fail("expected error for truncated stream")
  }
}

///|
test "brotli rejects trailing bytes after valid stream" {
  let compressed = hex_to_bytes("8b04804141414141424242424203") + b"\x01"
  let result = try? @brotli.decompress(compressed)
  match result {
    Err(BrotliError::CorruptData(msg)) =>
      assert_eq(msg, "trailing bytes after end of brotli stream")
    Err(err) => fail("expected trailing-data error, got \{err}")
    Ok(_) => fail("expected error for trailing bytes")
  }
}

///|
test "brotli rejects reserved metadata bit" {
  // Bits (LSB-first): WBITS=16, metadata block, reserved=1, empty final block.
  let result = try? @brotli.decompress(hex_to_bytes("9c01"))
  match result {
    Err(BrotliError::CorruptData(msg)) =>
      assert_eq(msg, "reserved metadata bit set")
    Err(err) => fail("expected reserved-bit error, got \{err}")
    Ok(_) => fail("expected error for reserved metadata bit")
  }
}

///|
/// Test decoding Go-compressed brotli (level 1, simple LZ77).
test "brotli decode Go-compressed level 1 simple" {
  let compressed = hex_to_bytes("8b04804141414141424242424203")
  let expected : Bytes = b"AAAAABBBBB"
  let decompressed = @brotli.decompress(compressed)
  assert_eq(decompressed, expected)
}

///|
/// Test decoding Go-compressed brotli (level 3, ABC repeat).
test "brotli decode Go-compressed level 3 ABC repeat" {
  let compressed = hex_to_bytes("1b3b000020838486e29b204603")
  let buf = @blit.Buffer::new()
  for _ in 0..<20 {
    buf.write_bytes(b"ABC")
  }
  let expected = buf.to_bytes()
  let decompressed = @brotli.decompress(compressed)
  assert_eq(decompressed, expected)
}

///|
test "brotli rejects oversubscribed Huffman code lengths" {
  // Mutated from the valid ABC repeat fixture above.
  let compressed = hex_to_bytes("1b3b000020828486e29b204603")
  let result = try? @brotli.decompress(compressed)
  match result {
    Err(BrotliError::CorruptData(msg)) =>
      assert_eq(msg, "oversubscribed Huffman code lengths")
    Err(BrotliError::UnexpectedEOF) => ()
    Err(err) => fail("expected a corrupt-stream error, got \{err}")
    Ok(_) => fail("expected error for oversubscribed Huffman code lengths")
  }
}

///|
/// Test decoding Go-compressed brotli (level 3, 100 bytes ABCDEFGHIJ repeat).
test "brotli decode Go-compressed level 3 100bytes" {
  let compressed = hex_to_bytes("1b630000c00dc6f6268d0030142828a7b3f7")
  let buf = @blit.Buffer::new()
  for _ in 0..<10 {
    buf.write_bytes(b"ABCDEFGHIJ")
  }
  let expected = buf.to_bytes()
  let decompressed = @brotli.decompress(compressed)
  assert_eq(decompressed, expected)
}

///|
/// Test decoding Go-compressed brotli (level 2, 100 bytes ABCDEFGHIJ repeat).
test "brotli decode Go-compressed level 2 100bytes" {
  let compressed = hex_to_bytes(
    "1b63000080aaaaaaeaff7ce655960138180b2231490c70a7cd05a0a09ccede53",
  )
  let buf = @blit.Buffer::new()
  for _ in 0..<10 {
    buf.write_bytes(b"ABCDEFGHIJ")
  }
  let expected = buf.to_bytes()
  let decompressed = @brotli.decompress(compressed)
  assert_eq(decompressed, expected)
}

///|
/// Test decoding Go-compressed brotli that uses the static dictionary.
/// The compressed data was generated by Go's brotli encoder at level 6
/// for the input: "The quick brown fox jumps over the lazy dog. This is a test of the emergency broadcast system."
test "brotli decode Go-compressed with dictionary" {
  let compressed = hex_to_bytes(
    "1b5d00000442b754f684c229848150206494cc1f8e71e078ddb5c0c0f3023a6c8c9dad44f48bcd02f38b9ffa74a2be94d3c642afcc0f8c5bddff11349992b463cbdaec19b237ae824003",
  )
  let expected : Bytes = b"The quick brown fox jumps over the lazy dog. This is a test of the emergency broadcast system."
  let decompressed = @brotli.decompress(compressed)
  assert_eq(decompressed, expected)
}

///|
fn hex_to_bytes(hex : String) -> Bytes {
  let len = hex.length() / 2
  let buf = @blit.Buffer::new(size_hint=len)
  for i in 0..<len {
    let hi = hex_digit(hex[i * 2].to_int())
    let lo = hex_digit(hex[i * 2 + 1].to_int())
    buf.write_byte(((hi << 4) | lo).to_byte())
  }
  buf.to_bytes()
}

///|
fn hex_digit(code : Int) -> Int {
  if code >= 0x30 && code <= 0x39 {
    code - 0x30
  } else if code >= 0x61 && code <= 0x66 {
    code - 0x61 + 10
  } else if code >= 0x41 && code <= 0x46 {
    code - 0x41 + 10
  } else {
    0
  }
}

///|
test "brotli decompress WOFF2 table data" {
  // Brotli-compressed WOFF2 font table data (323 bytes -> 634 bytes)
  // Compressed by Perl IO::Compress::Brotli (libbrotli 1.1.0)
  let compressed = hex_to_bytes(
    "1b7902609e07b66bb4301c8bdb623e160fe3e1ffd7d17df367c96c2486e6cc18e0b6674bdbba4e0d3a5d18ffe19aef4afcd35934772c342ac42634e215166eed3d9bed7483010fe839f018db4501261c6008691760790291761e70df1843722c8990be94210f11517f0a2c0e5f2eda8489283faddbb0b3112074e022b2d4505b7bbed5f2b1f6b55c42f43757bbd58c8fd7d827906d66c09c3463831e43a01a046f191fc141dcd4564c426af34740bc6667a00d109240b55c1f28950b99366e5180cf14b7c5b500048287fe23a3bad93755e905ee8f6d90e2a6cda85c06825172bc62dc002c85ec9bd727601912caace0445e811e70109a89c8d49a46d225e15cf628d1eafbd7a5bafcf84ece3eae3656d6ee884ea5b390be859bbbd2c6d1c6c1c49e2f12e92cac3cec4d5c536a25f6d1dd8716ae6e364e8e8846a696ef71407142df23",
  )
  let expected = hex_to_bytes(
    "0100040100010101104d696e696d616c2d526567756c61720001010108b30fb8118dcf12000000000000010022000301010203110e0ebd8b15f75cf95005f75cfd50050e8b14000401f4019000050000028a02580000004b028a02580000015e0032012c00000000000000000000000000000001000000000000000000000000544553540040002000410320ff380000032000c8000000010000000001f402bc00000020000000000001000300010000000c000400280000000600040001000200200041ffff000000200041ffffffe1ffc100010000000000000001000000010000e429937b5f0f3cf5000b03e800000000e39a360000000000e39a36000000000001c202bc00000008000200000000000100000320ff38000001f40000000001f400010000000000000000000000000000000301f4000000fa000001f4003200005000000300000007005a0003000104090000002600000003000104090001001400260003000104090002000e003a00030001040900030024004800030001040900040024006c0003000104090005001600900003000104090006002400a60043006f00700079007200690067006800740020003200300032003500200054006500730074004d0069006e0069006d0061006c0043004600460052006500670075006c00610072004d0069006e0069006d0061006c004300460046002d0052006500670075006c00610072004d0069006e0069006d0061006c00430046004600200052006500670075006c0061007200560065007200730069006f006e00200031002e0030004d0069006e0069006d0061006c004300460046002d0052006500670075006c006100720003000000000000ff9c003200000000",
  )
  let result = @brotli.decompress(compressed)
  assert_eq(result.length(), expected.length())
  for i in 0..<result.length() {
    if result[i] != expected[i] {
      fail(
        "first mismatch at byte \{i}: got 0x\{result[i].to_int().to_string(radix=16)}, expected 0x\{expected[i].to_int().to_string(radix=16)}",
      )
    }
  }
}

///|
test "debug repeated encoding size" {
  let data = Bytes::makei(4096, fn(i) {
    let phrase = b"abcdefghijklmnop"
    phrase[i % 16]
  })
  let compressed = @brotli.compress(data)
  guard compressed.length() < data.length()
  let c1 = @brotli.compress(data, level=@brotli.Level(1))
  guard c1.length() < data.length()
  let c0 = @brotli.compress(data, level=@brotli.Level(0))
  guard c0.length() > 0
}

///|
test "debug text_1mb levels" {
  let phrase = b"The quick brown fox jumps over the lazy dog. "
  let data = Bytes::makei(1048576, fn(i) { phrase[i % phrase.length()] })
  for lvl in [0, 1, 2, 4, 6, 9] {
    let compressed = @brotli.compress(data, level=@brotli.Level(lvl))
    guard compressed.length() > 0
  }
  let default_compressed = @brotli.compress(data)
  guard default_compressed.length() < data.length()
}
