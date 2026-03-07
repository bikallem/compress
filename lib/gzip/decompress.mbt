///|
/// Decompresses gzip-encoded data (RFC 1952).
/// Returns the decompressed data and the header metadata.
pub fn decompress(data : Bytes) -> (Bytes, Header) raise GzipError {
  // Need at least 10-byte header + 8-byte footer
  if data.length() < 18 {
    raise GzipError::UnexpectedEOF
  }
  // Check magic bytes
  if data[0] != gzip_magic1 || data[1] != gzip_magic2 {
    raise GzipError::InvalidHeader("invalid gzip magic bytes")
  }
  // Check compression method
  if data[2] != gzip_deflate {
    raise GzipError::InvalidHeader("unsupported compression method \{data[2]}")
  }
  let flg = data[3].to_int()
  // Modification time (4 bytes LE)
  let mtime = data[4].to_uint() |
    (data[5].to_uint() << 8) |
    (data[6].to_uint() << 16) |
    (data[7].to_uint() << 24)
  // XFL (extra flags) - we ignore it
  // OS
  let os = data[9]
  let mut pos = 10
  // Parse optional fields
  // FEXTRA
  let mut extra = Bytes::default()
  if (flg & gzip_fextra) != 0 {
    if pos + 2 > data.length() {
      raise GzipError::UnexpectedEOF
    }
    let xlen = data[pos].to_int() | (data[pos + 1].to_int() << 8)
    pos += 2
    if pos + xlen > data.length() {
      raise GzipError::UnexpectedEOF
    }
    let extra_buf = @buffer.new(size_hint=xlen)
    for i in pos..<(pos + xlen) {
      extra_buf.write_byte(data[i])
    }
    extra = extra_buf.to_bytes()
    pos += xlen
  }
  // FNAME
  let mut name = ""
  if (flg & gzip_fname) != 0 {
    let name_buf = @buffer.new()
    while pos < data.length() && data[pos] != b'\x00' {
      name_buf.write_byte(data[pos])
      pos += 1
    }
    if pos >= data.length() {
      raise GzipError::UnexpectedEOF
    }
    pos += 1 // skip null terminator
    // Treat as Latin-1 / ASCII
    let name_bytes = name_buf.to_bytes()
    let sb = StringBuilder::new()
    for i in 0..<name_bytes.length() {
      sb.write_char(name_bytes[i].to_int().unsafe_to_char())
    }
    name = sb.to_string()
  }
  // FCOMMENT
  let mut comment = ""
  if (flg & gzip_fcomment) != 0 {
    let comment_buf = @buffer.new()
    while pos < data.length() && data[pos] != b'\x00' {
      comment_buf.write_byte(data[pos])
      pos += 1
    }
    if pos >= data.length() {
      raise GzipError::UnexpectedEOF
    }
    pos += 1 // skip null terminator
    let comment_bytes = comment_buf.to_bytes()
    let sb = StringBuilder::new()
    for i in 0..<comment_bytes.length() {
      sb.write_char(comment_bytes[i].to_int().unsafe_to_char())
    }
    comment = sb.to_string()
  }
  // FHCRC
  if (flg & gzip_fhcrc) != 0 {
    if pos + 2 > data.length() {
      raise GzipError::UnexpectedEOF
    }
    // Skip 2-byte header CRC (we don't verify it)
    pos += 2
  }
  // Extract DEFLATE data (everything except last 8 bytes: CRC32 + ISIZE)
  let footer_start = data.length() - 8
  if pos >= footer_start {
    raise GzipError::UnexpectedEOF
  }
  let deflate_buf = @buffer.new(size_hint=footer_start - pos)
  for i in pos..<footer_start {
    deflate_buf.write_byte(data[i])
  }
  let deflate_data = deflate_buf.to_bytes()
  // Decompress DEFLATE data
  let decompressed = @flate.decompress(deflate_data) catch {
    e => raise GzipError::DeflateError(e.to_string())
  }
  // Verify CRC-32 (4 bytes LE)
  let expected_crc = data[footer_start].to_uint() |
    (data[footer_start + 1].to_uint() << 8) |
    (data[footer_start + 2].to_uint() << 16) |
    (data[footer_start + 3].to_uint() << 24)
  let actual_crc = @checksum.crc32(decompressed[:])
  if actual_crc != expected_crc {
    raise GzipError::ChecksumMismatch(expected=expected_crc, got=actual_crc)
  }
  // Verify ISIZE (4 bytes LE) - original size mod 2^32
  let expected_size = data[footer_start + 4].to_uint() |
    (data[footer_start + 5].to_uint() << 8) |
    (data[footer_start + 6].to_uint() << 16) |
    (data[footer_start + 7].to_uint() << 24)
  let actual_size = decompressed.length().reinterpret_as_uint() & 0xFFFFFFFF_U
  if actual_size != expected_size {
    raise GzipError::SizeMismatch(expected=expected_size, got=actual_size)
  }
  let header = Header::{ name, comment, extra, mod_time: mtime, os }
  (decompressed, header)
}
