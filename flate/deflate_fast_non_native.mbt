///|
fn match_len(data : Bytes, a : Int, b : Int, max_len : Int) -> Int {
  let mut n = 0
  while n < max_len && data[a + n] == data[b + n] {
    n += 1
  }
  n
}
