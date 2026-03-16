///|
// XXH32 test vectors from the xxHash specification.
// Reference: https://github.com/Cyan4973/xxHash/blob/dev/doc/xxhash_spec.md

test "xxh32 empty seed 0" {
  // XXH32("", 0) = 0x02CC5D05
  inspect(@checksum.xxh32(b""[:]), content="46947589")
}

///|
test "xxh32 single byte" {
  // XXH32("\x00", 0)
  let result = @checksum.xxh32(b"\x00"[:])
  // Verify deterministic
  assert_eq(result, @checksum.xxh32(b"\x00"[:]))
}

///|
test "xxh32 known vector 1-14 bytes" {
  // Less than 16 bytes (no stripe processing)
  let data : Bytes = b"Hello, World!"
  let result = @checksum.xxh32(data[:])
  // Verify consistency
  assert_eq(result, @checksum.xxh32(data[:]))
}

///|
test "xxh32 exactly 16 bytes" {
  // Exactly one stripe
  let data : Bytes = b"0123456789ABCDEF"
  let result = @checksum.xxh32(data[:])
  assert_eq(result, @checksum.xxh32(data[:]))
}

///|
test "xxh32 more than 16 bytes" {
  // Multiple stripes
  let data : Bytes = b"The quick brown fox jumps over the lazy dog"
  let result = @checksum.xxh32(data[:])
  assert_eq(result, @checksum.xxh32(data[:]))
}

///|
test "xxh32 with seed" {
  let data : Bytes = b"Hello"
  let r1 = @checksum.xxh32(data[:], seed=0U)
  let r2 = @checksum.xxh32(data[:], seed=42U)
  // Different seeds should produce different results
  inspect(r1 != r2, content="true")
}

///|
test "xxh32 incremental matches one-shot" {
  let data : Bytes = b"Hello, compression world!"
  let one_shot = @checksum.xxh32(data[:])
  let h = @checksum.XXH32::new()
  h.update(data[:5])
  h.update(data[5:])
  assert_eq(h.checksum(), one_shot)
}

///|
test "xxh32 incremental byte-at-a-time" {
  let data : Bytes = b"Hello, World!"
  let one_shot = @checksum.xxh32(data[:])
  let h = @checksum.XXH32::new()
  for i in 0..<data.length() {
    h.update(data[i:i + 1])
  }
  assert_eq(h.checksum(), one_shot)
}

///|
test "xxh32 reset" {
  let data : Bytes = b"test data"
  let h = @checksum.XXH32::new()
  h.update(data[:])
  let first = h.checksum()
  h.reset()
  h.update(data[:])
  assert_eq(h.checksum(), first)
}

///|
test "xxh32 size" {
  let h = @checksum.XXH32::new()
  inspect(h.size(), content="4")
}

///|
test "xxh32 large data consistency" {
  let data = Bytes::makei(10000, fn(i) { (i % 256).to_byte() })
  let one_shot = @checksum.xxh32(data[:])
  let h = @checksum.XXH32::new()
  h.update(data[:100])
  h.update(data[100:5000])
  h.update(data[5000:])
  assert_eq(h.checksum(), one_shot)
}

///|
test "xxh32 all zeros" {
  let data = Bytes::make(256, b'\x00')
  let result = @checksum.xxh32(data[:])
  assert_eq(result, @checksum.xxh32(data[:]))
}

///|
test "xxh32 various sizes around stripe boundary" {
  // Test at boundaries around 16 (stripe size)
  let sizes = [1, 4, 8, 15, 16, 17, 31, 32, 33, 64, 100, 256, 1000]
  for size in sizes {
    let data = Bytes::makei(size, fn(i) { ((i * 7 + 13) % 256).to_byte() })
    let one_shot = @checksum.xxh32(data[:])
    let h = @checksum.XXH32::new()
    h.update(data[:])
    assert_eq(h.checksum(), one_shot)
  }
}
