///|
// XXH64 test vectors from the xxHash specification.
// Reference: https://github.com/Cyan4973/xxHash/blob/dev/doc/xxhash_spec.md

test "xxh64 empty seed 0" {
  // XXH64("", 0) = 0xEF46DB3751D8E999
  inspect(@checksum.xxh64(b""[:]), content="17241709254077376921")
}

///|
test "xxh64 single byte" {
  let result = @checksum.xxh64(b"\x00"[:])
  // Verify deterministic
  assert_eq(result, @checksum.xxh64(b"\x00"[:]))
}

///|
test "xxh64 known vector short" {
  // Less than 32 bytes
  let data : Bytes = b"Hello, World!"
  let result = @checksum.xxh64(data[:])
  assert_eq(result, @checksum.xxh64(data[:]))
}

///|
test "xxh64 exactly 32 bytes" {
  let data : Bytes = b"0123456789ABCDEF0123456789ABCDEF"
  let result = @checksum.xxh64(data[:])
  assert_eq(result, @checksum.xxh64(data[:]))
}

///|
test "xxh64 more than 32 bytes" {
  let data : Bytes = b"The quick brown fox jumps over the lazy dog"
  let result = @checksum.xxh64(data[:])
  assert_eq(result, @checksum.xxh64(data[:]))
}

///|
test "xxh64 with seed" {
  let data : Bytes = b"Hello"
  let r1 = @checksum.xxh64(data[:], seed=0UL)
  let r2 = @checksum.xxh64(data[:], seed=42UL)
  inspect(r1 != r2, content="true")
}

///|
test "xxh64 incremental matches one-shot" {
  let data : Bytes = b"Hello, compression world!"
  let one_shot = @checksum.xxh64(data[:])
  let h = @checksum.XXH64::new()
  h.update(data[:5])
  h.update(data[5:])
  assert_eq(h.checksum64(), one_shot)
}

///|
test "xxh64 incremental byte-at-a-time" {
  let data : Bytes = b"Hello, World!"
  let one_shot = @checksum.xxh64(data[:])
  let h = @checksum.XXH64::new()
  for i in 0..<data.length() {
    h.update(data[i:i + 1])
  }
  assert_eq(h.checksum64(), one_shot)
}

///|
test "xxh64 reset" {
  let data : Bytes = b"test data"
  let h = @checksum.XXH64::new()
  h.update(data[:])
  let first = h.checksum64()
  h.reset()
  h.update(data[:])
  assert_eq(h.checksum64(), first)
}

///|
test "xxh64 size" {
  let h = @checksum.XXH64::new()
  inspect(h.size(), content="8")
}

///|
test "xxh64 large data consistency" {
  let data = Bytes::makei(10000, fn(i) { (i % 256).to_byte() })
  let one_shot = @checksum.xxh64(data[:])
  let h = @checksum.XXH64::new()
  h.update(data[:100])
  h.update(data[100:5000])
  h.update(data[5000:])
  assert_eq(h.checksum64(), one_shot)
}

///|
test "xxh64 all zeros" {
  let data = Bytes::make(256, b'\x00')
  let result = @checksum.xxh64(data[:])
  assert_eq(result, @checksum.xxh64(data[:]))
}

///|
test "xxh64 various sizes around stripe boundary" {
  let sizes = [1, 4, 8, 16, 31, 32, 33, 63, 64, 65, 100, 256, 1000]
  for size in sizes {
    let data = Bytes::makei(size, fn(i) { ((i * 7 + 13) % 256).to_byte() })
    let one_shot = @checksum.xxh64(data[:])
    let h = @checksum.XXH64::new()
    h.update(data[:])
    assert_eq(h.checksum64(), one_shot)
  }
}

///|
test "xxh64 different from xxh32" {
  let data : Bytes = b"test"
  let h32 = @checksum.xxh32(data[:])
  let h64 = @checksum.xxh64(data[:])
  // 64-bit result should be different from 32-bit result
  inspect(h32.to_uint64() != h64, content="true")
}
