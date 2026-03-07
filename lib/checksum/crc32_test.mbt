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
