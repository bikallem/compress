///|
const DEFAULT_SLICE_LENGTH = 65536

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
    return b""
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

///|
pub impl Reader for BytesReader with read_byte(self) -> Byte {
  guard self.offset < self.data.length() else { raise UnexpectedEod }
  let b = self.data[self.offset]
  self.offset += 1
  b
}
