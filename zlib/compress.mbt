///|
/// Compresses data using zlib format (RFC 1950).
pub fn compress(
  data : Bytes,
  level? : @flate.CompressionLevel = DefaultCompression,
) -> Bytes raise ZlibError {
  compress_with_dict(data, Bytes::default(), level~)
}

///|
/// Compresses data using zlib format with a preset dictionary.
pub fn compress_with_dict(
  data : Bytes,
  dict : Bytes,
  level? : @flate.CompressionLevel = DefaultCompression,
) -> Bytes raise ZlibError {
  let buf = @buffer.new(size_hint=data.length() + 12)
  // Build CMF byte: CINFO (4 bits) | CM (4 bits)
  // CM = 8 (deflate), CINFO = 7 (32K window)
  let cmf = (ZLIB_DEFAULT_CINFO << 4) | ZLIB_DEFLATE_METHOD
  // Build FLG byte: FLEVEL (2 bits) | FDICT (1 bit) | FCHECK (5 bits)
  let flevel = match level {
    NoCompression | HuffmanOnly => 0
    BestSpeed | Level(1) | Level(2) => 1
    Level(n) => if n <= 5 { 1 } else { 2 }
    BestCompression => 3
    DefaultCompression => 2
  }
  let fdict = if dict.length() > 0 { 1 } else { 0 }
  let mut flg = (flevel << 6) | (fdict << 5)
  // Set FCHECK so that (CMF*256 + FLG) is a multiple of 31
  let remainder = (cmf * 256 + flg) % 31
  if remainder != 0 {
    flg += 31 - remainder
  }
  buf.write_byte(cmf.to_byte())
  buf.write_byte(flg.to_byte())
  // Write DICTID if dictionary provided
  if dict.length() > 0 {
    let dict_checksum = @checksum.adler32(dict[:])
    buf.write_byte(((dict_checksum >> 24) & 0xFFU).to_byte())
    buf.write_byte(((dict_checksum >> 16) & 0xFFU).to_byte())
    buf.write_byte(((dict_checksum >> 8) & 0xFFU).to_byte())
    buf.write_byte((dict_checksum & 0xFFU).to_byte())
  }
  // Compress with DEFLATE
  let compressed = try {
    if dict.length() > 0 {
      @flate.compress_with_dict(data, dict, level~)
    } else {
      @flate.compress(data, level~)
    }
  } catch {
    e => raise ZlibError::DeflateError(e.to_string())
  }
  // Write compressed data
  for i in 0..<compressed.length() {
    buf.write_byte(compressed[i])
  }
  // Write Adler-32 checksum of original data (big-endian)
  let checksum = @checksum.adler32(data[:])
  buf.write_byte(((checksum >> 24) & 0xFFU).to_byte())
  buf.write_byte(((checksum >> 16) & 0xFFU).to_byte())
  buf.write_byte(((checksum >> 8) & 0xFFU).to_byte())
  buf.write_byte((checksum & 0xFFU).to_byte())
  buf.to_bytes()
}
