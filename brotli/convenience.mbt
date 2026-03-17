///|
/// Decompress Brotli-encoded data (RFC 7932).
pub fn decompress(data : Bytes) -> Bytes raise BrotliError {
  let inflater = Inflater::new()
  inflater.src(data[:])
  inflater.enable_direct_output((data.length() * 2).max(32768))
  loop inflater.decode() {
    Await => raise BrotliError::UnexpectedEOF
    Data(_) => continue inflater.decode()
    End => inflater.take_output()
    Error(e) => raise e
  }
}

///|
/// Compress data with Brotli.
pub fn compress(
  data : Bytes,
  level? : CompressionLevel = DefaultCompression,
) -> Bytes raise BrotliError {
  let deflater = Deflater::new(level~)
  let buf = @buffer.new(size_hint=data.length() + 64)
  drain(deflater, buf, Some(data[:]))
  drain(deflater, buf, None)
  buf.to_bytes()
}

///|
fn drain(
  deflater : Deflater,
  buf : @buffer.Buffer,
  input : BytesView?,
) -> Unit raise BrotliError {
  match deflater.encode(input) {
    Ok | End => ()
    Data(chunk) => buf.write_bytes(chunk)
    Error(e) => raise e
  }
}
