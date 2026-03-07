///|
/// Inflater provides sync streaming DEFLATE decompression.
/// Feed compressed chunks via `update()`, get decompressed output via `finish()`.
pub struct Inflater {
  dict : Bytes
  buf : @buffer.Buffer
}

///|
/// Creates a new Inflater.
pub fn Inflater::new(dict? : Bytes = Bytes::default()) -> Inflater {
  { dict, buf: @buffer.new() }
}

///|
/// Appends a chunk of compressed data.
pub fn Inflater::update(self : Inflater, chunk : Bytes) -> Unit {
  for i in 0..<chunk.length() {
    self.buf.write_byte(chunk[i])
  }
}

///|
/// Finishes decompression and returns the decompressed output.
pub fn Inflater::finish(self : Inflater) -> Bytes raise @flate.CompressError {
  let data = self.buf.to_bytes()
  if self.dict.length() > 0 {
    @flate.decompress_with_dict(data, self.dict)
  } else {
    @flate.decompress(data)
  }
}
