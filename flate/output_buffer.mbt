///|
/// Fast output buffer for decompression, replacing @buffer.Buffer.
/// Uses unsafe_set for writes and unsafe_blit for grows to avoid
/// bounds-check overhead in the hot path.
priv struct OutputBuffer {
  mut data : FixedArray[Byte]
  mut len : Int
}

///|
fn OutputBuffer::new(size_hint : Int) -> OutputBuffer {
  {
    data: FixedArray::make(if size_hint > 0 { size_hint } else { 4096 }, b'\x00'),
    len: 0,
  }
}

///|
/// Grow the buffer to hold at least `required` total bytes.
fn OutputBuffer::grow(self : OutputBuffer, required : Int) -> Unit {
  let mut new_cap = self.data.length()
  while new_cap < required {
    new_cap = new_cap * 2
  }
  let new_data = FixedArray::make(new_cap, b'\x00')
  FixedArray::unsafe_blit(new_data, 0, self.data, 0, self.len)
  self.data = new_data
}

///|
/// Write a contiguous slice from a FixedArray[Byte].
fn OutputBuffer::write_fixed(
  self : OutputBuffer,
  src : FixedArray[Byte],
  start : Int,
  len : Int,
) -> Unit {
  let required = self.len + len
  if required > self.data.length() {
    self.grow(required)
  }
  FixedArray::unsafe_blit(self.data, self.len, src, start, len)
  self.len += len
}

///|
/// Convert to final Bytes output. Zero-copy when buffer is exact size.
fn OutputBuffer::to_bytes(self : OutputBuffer) -> Bytes {
  if self.len == self.data.length() {
    return self.data.unsafe_reinterpret_as_bytes()
  }
  let result = FixedArray::make(self.len, b'\x00')
  FixedArray::unsafe_blit(result, 0, self.data, 0, self.len)
  result.unsafe_reinterpret_as_bytes()
}
