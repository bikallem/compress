///|
/// Compresses data using zlib format with a preset dictionary.
pub fn compress(
  data : Bytes,
  dict? : Bytes = Bytes::default(),
  level? : @flate.CompressionLevel = DefaultCompression,
) -> Bytes raise ZlibError {
  let buf = @buffer.new(size_hint=data.length() + 12)
  buf.write_bytes(build_zlib_header(level, dict))
  // Compress with DEFLATE
  let compressed = try {
    if dict.length() > 0 {
      let def = @flate.Deflater::new(level~, dict~)
      let buf = @buffer.new()
      match def.encode(Some(data[:])) {
        Data(chunk) => buf.write_bytesview(chunk)
        Ok | End | Error(_) => ()
      }
      match def.encode(None) {
        Data(chunk) => buf.write_bytesview(chunk)
        Ok | End | Error(_) => ()
      }
      buf.to_bytes()
    } else {
      @flate.compress(data, level~)
    }
  } catch {
    e => raise ZlibError::DeflateError(e.to_string())
  }
  buf.write_bytes(compressed)
  // Adler-32 of original data (big-endian)
  let checksum = @checksum.adler32(data[:])
  buf.write_uint_be(checksum)
  buf.to_bytes()
}

///|
fn build_zlib_header(level : @flate.CompressionLevel, dict : Bytes) -> Bytes {
  let buf = @buffer.new(size_hint=6)
  let cmf = (ZLIB_DEFAULT_CINFO << 4) | ZLIB_DEFLATE_METHOD
  let flevel = match level {
    NoCompression | HuffmanOnly => 0
    BestSpeed | Level(1) | Level(2) => 1
    Level(n) => if n <= 5 { 1 } else { 2 }
    BestCompression => 3
    DefaultCompression => 2
  }
  let fdict = if dict.length() > 0 { 1 } else { 0 }
  let mut flg = (flevel << 6) | (fdict << 5)
  let remainder = (cmf * 256 + flg) % 31
  if remainder != 0 {
    flg += 31 - remainder
  }
  buf.write_byte(cmf.to_byte())
  buf.write_byte(flg.to_byte())
  if dict.length() > 0 {
    let dict_checksum = @checksum.adler32(dict[:])
    buf.write_uint_be(dict_checksum)
  }
  buf.to_bytes()
}
