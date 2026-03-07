///|
fn main {
  // bzip2-compressed "Hello"
  let compressed : Bytes = [
    0x42, 0x5A, 0x68, 0x39, 0x31, 0x41, 0x59, 0x26, 0x53, 0x59, 0x1A, 0x54, 0x64,
    0x92, 0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0x40, 0x02, 0x04, 0xA0, 0x00, 0x21,
    0x9A, 0x68, 0x33, 0x4D, 0x13, 0x33, 0x8B, 0xB9, 0x22, 0x9C, 0x28, 0x48, 0x0D,
    0x2A, 0x32, 0x49, 0x00,
  ]
  let result : Result[Bytes, Error] = try? @bzip2.decompress(compressed)
  match result {
    Ok(decompressed) => {
      println("bzip2 decompressed: \{decompressed.length()} bytes")
      let expected = b"Hello"
      guard decompressed == expected else {
        println("Content mismatch!")
        return
      }
      println("Content: OK")
    }
    Err(e) => println("Error: \{e}")
  }

  // --- Error handling ---
  let bad_result : Result[Bytes, Error] = try? @bzip2.decompress(
    b"\x00\x01\x02",
  )
  match bad_result {
    Err(e) => println("Expected error: \{e}")
    Ok(_) => println("Unexpected success")
  }
}
