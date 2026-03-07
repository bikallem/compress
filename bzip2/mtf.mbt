///|
/// Move-to-front transform decoder.
/// Given an MTF-encoded sequence and an initial symbol list,
/// decodes back to original symbols.
fn _mtf_decode(
  symbols : FixedArray[Int],
  length : Int,
  list : FixedArray[Byte],
) -> Unit {
  for i in 0..<length {
    let idx = symbols[i]
    let val = list[idx]
    // Move to front
    for j = idx; j > 0; j = j - 1 {
      list[j] = list[j - 1]
    }
    list[0] = val
    symbols[i] = val.to_int()
  }
}
