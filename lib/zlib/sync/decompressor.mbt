///|
/// ZlibDecompressor provides sync streaming zlib decompression.
pub struct ZlibDecompressor {
  dict : Bytes
  buf : @buffer.Buffer
}

///|
pub fn ZlibDecompressor::new(
  dict? : Bytes = Bytes::default(),
) -> ZlibDecompressor {
  { dict, buf: @buffer.new() }
}

///|
pub fn ZlibDecompressor::update(self : ZlibDecompressor, chunk : Bytes) -> Unit {
  for i in 0..<chunk.length() {
    self.buf.write_byte(chunk[i])
  }
}

///|
pub fn ZlibDecompressor::finish(
  self : ZlibDecompressor,
) -> Bytes raise @zlib.ZlibError {
  let data = self.buf.to_bytes()
  if self.dict.length() > 0 {
    @zlib.decompress_with_dict(data, self.dict)
  } else {
    @zlib.decompress(data)
  }
}
