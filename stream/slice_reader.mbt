///|
const DEFAULT_SLICE_LENGTH : Int = 65536

///|
/// Reads from a `Bytes` source, yielding `slice_length`-bounded chunks.
struct SliceReader {
  data : Bytes
  mut offset : Int
  slice_length : Int
}

///|
pub fn SliceReader::new(
  data : Bytes,
  slice_length? : Int = DEFAULT_SLICE_LENGTH,
) -> SliceReader {
  { data, offset: 0, slice_length }
}

///|
pub impl Reader for SliceReader with read(self) {
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
