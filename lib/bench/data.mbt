///|
/// Generate repeated text data of approximately the given size.
fn gen_text(size : Int) -> Bytes {
  let phrase = b"The quick brown fox jumps over the lazy dog. "
  let buf = @buffer.new(size_hint=size)
  for i = 0; i < size; i = i + 1 {
    buf.write_byte(phrase[i % phrase.length()])
  }
  buf.to_bytes()
}

///|
/// Generate all-zero data.
fn gen_zeros(size : Int) -> Bytes {
  Bytes::make(size, 0)
}

///|
/// Generate pseudo-random data (incompressible).
fn gen_random(size : Int) -> Bytes {
  let buf = FixedArray::make(size, b'\x00')
  // Simple LCG for reproducible pseudo-random data
  for i = 0, state = 0x12345678U; i < size; {
    let next_state = state * 1103515245U + 12345U
    buf[i] = ((next_state >> 16) & 0xFFU).to_byte()
    continue i + 1, next_state
  }
  Bytes::from_array(buf)
}
