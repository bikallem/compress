///|
fn main {
  let phrase = b"The quick brown fox jumps over the lazy dog. "
  let data = Bytes::makei(10485760, fn(i) { phrase[i % phrase.length()] })
  let compressed = try! @bz2.compress(data)
  println("size=\{compressed.length()}")
}
