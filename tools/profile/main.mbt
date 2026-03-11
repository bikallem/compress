///|
fn gen_text(size : Int) -> Bytes {
  let buf = @buffer.new(size_hint=size)
  let phrases : FixedArray[String] = [
    "the quick brown fox jumps over the lazy dog ", "lorem ipsum dolor sit amet consectetur adipiscing elit ",
    "pack my box with five dozen liquor jugs ", "how vexingly quick daft zebras jump ",
    "the five boxing wizards jump quickly ",
  ]
  let mut i = 0
  let mut phrase_idx = 0
  while i < size {
    let phrase = phrases[phrase_idx]
    for j in 0..<phrase.length() {
      if i >= size {
        break
      }
      buf.write_byte(phrase[j].to_int().to_byte())
      i += 1
    }
    phrase_idx = (phrase_idx + 1) % phrases.length()
  }
  buf.to_bytes()
}

///|
fn main {
  let data = gen_text(104857600) // 100MB
  let _ = try! @flate2.compress(data)
}
