///|
/// Compresses data using gzip format (RFC 1952).
pub fn compress(
  data : Bytes,
  level? : @flate.CompressionLevel = DefaultCompression,
  header? : Header = { ..Header::default() },
) -> Bytes raise GzipError {
  let buf = @blit.Buffer::new(size_hint=data.length() + 32)
  buf.write_bytes(build_gzip_header(header, level))
  // Compress with DEFLATE
  let compressed = @flate.compress(data, level~) catch {
    e => raise GzipError::DeflateError(e.to_string())
  }
  buf.write_bytes(compressed)
  // CRC-32 (4 bytes LE)
  let crc = @checksum.crc32(data[:])
  write_uint_le(buf, crc)
  // ISIZE (4 bytes LE) - original size mod 2^32
  let isize = data.length().reinterpret_as_uint() & 0xFFFFFFFF_U
  write_uint_le(buf, isize)
  buf.to_bytes()
}

///|
fn build_gzip_header(header : Header, level : @flate.CompressionLevel) -> Bytes {
  let buf = @blit.Buffer::new(size_hint=32)
  // Magic bytes
  buf.write_byte(GZIP_MAGIC1)
  buf.write_byte(GZIP_MAGIC2)
  // Compression method: deflate
  buf.write_byte(GZIP_DEFLATE)
  // Build FLG byte
  let mut flg = GZIP_FHCRC
  if header.name.length() > 0 {
    flg = flg | GZIP_FNAME
  }
  if header.comment.length() > 0 {
    flg = flg | GZIP_FCOMMENT
  }
  if header.extra.length() > 0 {
    flg = flg | GZIP_FEXTRA
  }
  buf.write_byte(flg.to_byte())
  // MTIME (4 bytes LE)
  write_uint_le(buf, header.mod_time)
  // XFL (extra flags based on compression level)
  let xfl : Byte = match level {
    BestCompression => 2
    BestSpeed => 4
    _ => 0
  }
  buf.write_byte(xfl)
  // OS
  buf.write_byte(header.os)
  // FEXTRA
  if header.extra.length() > 0 {
    let xlen = header.extra.length()
    buf.write_byte((xlen & 0xFF).to_byte())
    buf.write_byte((xlen >> 8).to_byte())
    buf.write_bytes(header.extra)
  }
  // FNAME
  if header.name.length() > 0 {
    for c in header.name {
      buf.write_byte((c.to_int() & 0xFF).to_byte())
    }
    buf.write_byte(b'\x00')
  }
  // FCOMMENT
  if header.comment.length() > 0 {
    for c in header.comment {
      buf.write_byte((c.to_int() & 0xFF).to_byte())
    }
    buf.write_byte(b'\x00')
  }
  // FHCRC: CRC-32 of header so far, truncated to 16 bits (LE)
  let header_bytes = buf.to_bytes()
  let hcrc = @checksum.crc32(header_bytes[:])
  buf.write_byte((hcrc & 0xFFU).to_byte())
  buf.write_byte(((hcrc >> 8) & 0xFFU).to_byte())
  buf.to_bytes()
}

///|
/// Compresses multiple data segments as a multi-member gzip archive (RFC 1952).
/// Each entry produces a separate gzip member; concatenated members form a valid archive.
pub fn compress_members(
  members : Array[(Bytes, Header)],
  level? : @flate.CompressionLevel = DefaultCompression,
) -> Bytes raise GzipError {
  let buf = @blit.Buffer::new()
  for entry in members {
    let (data, header) = entry
    buf.write_bytes(compress(data, level~, header~))
  }
  buf.to_bytes()
}

///|
fn write_uint_le(buf : @blit.Buffer, v : UInt) -> Unit {
  buf.write_byte((v & 0xFF_U).to_byte())
  buf.write_byte(((v >> 8) & 0xFF_U).to_byte())
  buf.write_byte(((v >> 16) & 0xFF_U).to_byte())
  buf.write_byte(((v >> 24) & 0xFF_U).to_byte())
}
