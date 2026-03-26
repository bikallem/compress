///|
/// Decompresses gzip-encoded data (RFC 1952).
/// Returns the decompressed data and the header metadata.
pub fn decompress(data : Bytes) -> (Bytes, Header) raise GzipError {
  let inf = Inflater::new()
  let sink = @blit.Buffer::new(size_hint=(data.length() * 2).max(32768))
  inf.src(data[:])
  loop inf.decode() {
    Await => raise GzipError::UnexpectedEOF
    Data(chunk) => {
      sink.write_bytesview(chunk)
      continue inf.decode()
    }
    End => (sink.to_bytes(), inf.header())
    Error(e) => raise e
  }
}

///|
fn gzip_header_crc16(data : BytesView, header_len : Int) -> UInt {
  @checksum.crc32(data[0:header_len]) & 0xFFFFU
}
