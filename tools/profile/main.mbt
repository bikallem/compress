///|
fn main {
  let phrase = b"The quick brown fox jumps over the lazy dog. "
  let sizes = [
    5, 10, 20, 45, 46, 50, 90, 91, 100, 200, 256, 500, 1000, 5000, 10000,
    100000, 900000,
  ]
  let mut pass = 0
  let mut fail = 0
  for size in sizes {
    let data = Bytes::makei(size, fn(i) { phrase[i % phrase.length()] })
    let compressed = try? @bz2.compress(data)
    match compressed {
      Err(e) => {
        println("FAIL size=\{size}: compress error: \{e}")
        fail += 1
      }
      Ok(c) => {
        let d = try? @bz2.decompress(c)
        match d {
          Err(e) => {
            println("FAIL size=\{size}: decompress error: \{e}")
            fail += 1
          }
          Ok(d) =>
            if data == d {
              pass += 1
            } else {
              println("FAIL size=\{size}: data mismatch")
              fail += 1
            }
        }
      }
    }
  }
  println("\{pass} passed, \{fail} failed out of \{sizes.length()}")
}
