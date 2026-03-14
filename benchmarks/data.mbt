///|
/// Generate repeated text data of approximately the given size.
pub fn gen_text(size : Int) -> Bytes {
  let phrase = b"The quick brown fox jumps over the lazy dog. "
  Bytes::makei(size, fn(i) { phrase[i % phrase.length()] })
}

///|
/// Generate all-zero data.
pub fn gen_zeros(size : Int) -> Bytes {
  Bytes::make(size, 0)
}

///|
/// Generate pseudo-random data (incompressible).
/// Uses glibc LCG constants for reproducible output; >>16 avoids low-bit patterns.
pub fn gen_random(size : Int) -> Bytes {
  let buf = FixedArray::make(size, b'\x00')
  for i = 0, state = 0x12345678U; i < size; {
    let next_state = state * 1103515245U + 12345U
    buf[i] = ((next_state >> 16) & 0xFFU).to_byte()
    continue i + 1, next_state
  }
  Bytes::from_array(buf)
}
