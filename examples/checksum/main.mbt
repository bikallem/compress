///|
fn run() -> Unit raise {
  let data = b"Hello, compression world!"

  // --- Convenience functions ---
  let crc = @cksum.crc32(data[:])
  println("CRC-32:  \{crc}")

  let adler = @cksum.adler32(data[:])
  println("Adler-32: \{adler}")

  // --- Stateful Hasher (for incremental hashing) ---
  let h = @cksum.CRC32::new()
  h.update(data[:5]) // "Hello"
  h.update(data[5:]) // ", compression world!"
  let incremental_crc = h.checksum()
  println("CRC-32 (incremental): \{incremental_crc}")
  assert_eq(incremental_crc, crc)

  // Reset and reuse
  h.reset()
  h.update(data[:])
  println("CRC-32 (after reset): \{h.checksum()}")

  // --- Hasher trait usage (generic) ---
  fn hash_with(hasher : &@cksum.Hasher, data : BytesView) -> UInt {
    hasher.reset()
    hasher.update(data)
    hasher.checksum()
  }

  let a = @cksum.Adler32::new()
  println("Adler-32 (via trait): \{hash_with(a, data[:])}")
  println("Hash output size: \{a.size()} bytes")
}

///|
fn main {
  run() catch {
    e => println("Error: \{e}")
  }
}
