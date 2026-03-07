///|
/// Streaming decompression of DEFLATE data from a reader to a writer.
/// Returns any bytes that were read from source but not consumed by DEFLATE.
pub async fn decompress_to(source : &@io.Reader, dest : &@io.Writer) -> Bytes {
  decompress_to_with_dict(source, dest, Bytes::default())
}

///|
/// Streaming decompression of DEFLATE data with a preset dictionary.
/// Returns any bytes that were read from source but not consumed by DEFLATE.
pub async fn decompress_to_with_dict(
  source : &@io.Reader,
  dest : &@io.Writer,
  dict : Bytes,
) -> Bytes {
  // Read all remaining data from source
  let input_buf = @buffer.new()
  let tmp = FixedArray::make(4096, b'\x00')
  while true {
    let n = source.read(tmp, offset=0, max_len=4096)
    if n == 0 {
      break
    }
    for i in 0..<n {
      input_buf.write_byte(tmp[i])
    }
  }
  let input = input_buf.to_bytes()
  // Decompress using the sync core algorithm
  let (decompressed, remaining) = decompress_core(input, dict)
  // Write decompressed data to dest
  let mut written = 0
  while written < decompressed.length() {
    let n = dest.write_once(
      decompressed,
      offset=written,
      len=decompressed.length() - written,
    )
    written += n
  }
  remaining
}
