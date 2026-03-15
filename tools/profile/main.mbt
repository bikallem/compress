///|
fn main {
  // Test SA-IS directly against a known correct BWT
  // "banana" -> BWT = "annb$aa" (with sentinel), or circular: "nnbaaa" with orig_ptr=3
  // Let's test bzip2 round-trip at the problematic size
  let phrase = b"The quick brown fox jumps over the lazy dog. "
  let data = Bytes::makei(100, fn(i) { phrase[i % phrase.length()] })

  // Compress, then try to decompress with system bzip2 to verify format
  let compressed = try! @bz2.compress(data)
  println("compressed \{data.length()} -> \{compressed.length()}")

  // Check if system bzip2 can decompress it
  // (this would confirm the format is correct)
  let decompressed = try! @bz2.decompress(compressed)
  println("decompressed: \{decompressed.length()}")
  println("match: \{data == decompressed}")
  if data != decompressed {
    for i in 0..<data.length() {
      if i >= decompressed.length() || data[i] != decompressed[i] {
        println("first diff at byte \{i}")
        break
      }
    }
  }
}
