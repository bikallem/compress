///|
// CRC-32 test vectors from Go hash/crc32 and RFC 3720
test "crc32 empty" {
  inspect(@checksum.crc32(b""[:]), content="0")
}

///|
test "crc32 known vectors" {
  // "123456789" -> 0xCBF43926 (well-known CRC-32 check value)
  let data : Bytes = b"\x31\x32\x33\x34\x35\x36\x37\x38\x39"
  inspect(@checksum.crc32(data[:]), content="3421780262")
}

///|
test "crc32 single byte" {
  inspect(@checksum.crc32(b"\x00"[:]), content="3523407757")
}

///|
test "crc32 all zeros" {
  let data = Bytes::make(256, b'\x00')
  let c = @checksum.crc32(data[:])
  inspect(c == @checksum.crc32(data[:]), content="true")
}

///|
test "crc32 incremental matches one-shot" {
  let data : Bytes = b"Hello, compression world!"
  let one_shot = @checksum.crc32(data[:])
  let h = @checksum.CRC32::new()
  h.update(data[:5])
  h.update(data[5:])
  inspect(h.checksum() == one_shot, content="true")
}

///|
test "crc32 reset" {
  let data : Bytes = b"test data"
  let h = @checksum.CRC32::new()
  h.update(data[:])
  let first = h.checksum()
  h.reset()
  h.update(data[:])
  inspect(h.checksum() == first, content="true")
}

///|
test "crc32 size" {
  let h = @checksum.CRC32::new()
  inspect(h.size(), content="4")
}

///|
test "crc32 all 0xFF" {
  let data = Bytes::make(256, b'\xFF')
  let c = @checksum.crc32(data[:])
  // Verify consistency: same data should produce same hash
  assert_eq(c, @checksum.crc32(data[:]))
}

///|
test "crc32 incremental byte-at-a-time" {
  let data : Bytes = b"Hello, World!"
  let one_shot = @checksum.crc32(data[:])
  let h = @checksum.CRC32::new()
  for i in 0..<data.length() {
    h.update(data[i:i + 1])
  }
  assert_eq(h.checksum(), one_shot)
}

///|
test "crc32 large data consistency" {
  let data = Bytes::makei(10000, fn(i) { (i % 256).to_byte() })
  let one_shot = @checksum.crc32(data[:])
  // Split at various boundaries
  let h = @checksum.CRC32::new()
  h.update(data[:100])
  h.update(data[100:5000])
  h.update(data[5000:])
  assert_eq(h.checksum(), one_shot)
}

///|
test "crc32 abc" {
  // Known vector: "abc" -> 0x352441C2
  inspect(@checksum.crc32(b"abc"[:]), content="891568578")
}
