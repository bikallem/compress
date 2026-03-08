///|
const DEFAULT_SLICE_LENGTH : Int = 65536

///|
/// Reads from a `Bytes` source, yielding `slice_length`-bounded chunks.
struct BytesReader {
  data : Bytes
  mut offset : Int
  slice_length : Int
}

///|
pub fn BytesReader::new(
  data : Bytes,
  slice_length? : Int = DEFAULT_SLICE_LENGTH,
) -> BytesReader {
  { data, offset: 0, slice_length }
}

///|
pub impl Reader for BytesReader with read(self) -> BytesView {
  if self.offset >= self.data.length() {
    return b""[:]
  }
  let remaining = self.data.length() - self.offset
  let n = if remaining < self.slice_length {
    remaining
  } else {
    self.slice_length
  }
  let view = self.data[self.offset:self.offset + n]
  self.offset += n
  view
}
