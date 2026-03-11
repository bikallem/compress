///|
/// Decompress DEFLATE-encoded data (RFC 1951).
pub fn decompress(data : Bytes) -> Bytes raise CompressError {
  let d = Inflater::new()
  d.src(data)
  let buf = @buffer.new()
  loop d.decode() {
    Await => raise CompressError::UnexpectedEOF
    Data(chunk) => {
      buf.write_bytes(chunk)
      continue d.decode()
    }
    End => buf.to_bytes()
    Error(e) => raise e
  }
}

///|
/// Decompress DEFLATE-encoded data with a preset dictionary.
pub fn decompress_with_dict(
  data : Bytes,
  dict : Bytes,
) -> Bytes raise CompressError {
  let d = Inflater::new(dict~)
  d.src(data)
  let buf = @buffer.new()
  loop d.decode() {
    Await => raise CompressError::UnexpectedEOF
    Data(chunk) => {
      buf.write_bytes(chunk)
      continue d.decode()
    }
    End => buf.to_bytes()
    Error(e) => raise e
  }
}

///|
/// Compress data using DEFLATE (RFC 1951).
pub fn compress(
  data : Bytes,
  level? : CompressionLevel = DefaultCompression,
) -> Bytes raise CompressError {
  let e = Deflater::new(level~)
  let buf = @buffer.new()
  drain(e, buf, Some(data))
  drain(e, buf, None)
  buf.to_bytes()
}

///|
fn drain(
  e : Deflater,
  buf : @buffer.Buffer,
  input : Bytes?,
) -> Unit raise CompressError {
  loop e.encode(input) {
    Ok | End => ()
    Data(chunk) => {
      buf.write_bytes(chunk)
      continue e.encode(input)
    }
    Error(e) => raise e
  }
}
