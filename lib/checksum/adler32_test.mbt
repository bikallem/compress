///|
// Adler-32 test vectors from Go hash/adler32
test "adler32 empty" {
  // Adler-32 of empty data is 1
  inspect(@checksum.adler32(b""[:]), content="1")
}

///|
test "adler32 single byte a" {
  // s1 = 1 + 97 = 98, s2 = 0 + 98 = 98
  // result = 98 << 16 | 98 = 6422626
  let data : Bytes = b"\x61"
  inspect(@checksum.adler32(data[:]), content="6422626")
}

///|
test "adler32 known vector" {
  // "Wikipedia" -> 0x11E60398
  let data : Bytes = b"Wikipedia"
  inspect(@checksum.adler32(data[:]), content="300286872")
}

///|
test "adler32 incremental matches one-shot" {
  let data : Bytes = b"Hello, compression world!"
  let one_shot = @checksum.adler32(data[:])
  let h = @checksum.Adler32::new()
  h.update(data[:5])
  h.update(data[5:])
  inspect(h.checksum() == one_shot, content="true")
}

///|
test "adler32 large input" {
  // Test with data larger than nmax (5552) to exercise chunking
  let data = Bytes::make(6000, b'\x41')
  let one_shot = @checksum.adler32(data[:])
  let h = @checksum.Adler32::new()
  h.update(data[:3000])
  h.update(data[3000:])
  inspect(h.checksum() == one_shot, content="true")
}

///|
test "adler32 reset" {
  let data : Bytes = b"test"
  let h = @checksum.Adler32::new()
  h.update(data[:])
  let first = h.checksum()
  h.reset()
  h.update(data[:])
  inspect(h.checksum() == first, content="true")
}

///|
test "adler32 size" {
  let h = @checksum.Adler32::new()
  inspect(h.size(), content="4")
}
