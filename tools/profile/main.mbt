///|
fn main {
  let phrase = b"The quick brown fox jumps over the lazy dog. "
  let data = Bytes::makei(1048576, fn(i) { phrase[i % phrase.length()] })
  let compressed = try! @flate.compress(data)
  println("compressed \{data.length()} -> \{compressed.length()}")
}
