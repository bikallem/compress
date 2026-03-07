///|
/// Streaming decompression of LZW data from a reader to a writer.
pub async fn decompress_to(
  source : &@io.Reader,
  dest : &@io.Writer,
  order : BitOrder,
  lit_width : Int,
) -> Unit {
  // Read all input from source
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
  // Decompress using the sync algorithm
  let decompressed = decompress(input, order, lit_width)
  // Write output to dest
  let mut written = 0
  while written < decompressed.length() {
    let n = dest.write_once(
      decompressed,
      offset=written,
      len=decompressed.length() - written,
    )
    written += n
  }
}
