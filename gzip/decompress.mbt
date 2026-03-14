///|
/// Decompresses gzip-encoded data (RFC 1952).
/// Returns the decompressed data and the header metadata.
pub fn decompress(data : Bytes) -> (Bytes, Header) raise GzipError {
  // Need at least 10-byte header + 8-byte footer
  if data.length() < 18 {
    raise GzipError::UnexpectedEOF
  }
  let (pos, header) = parse_gzip_header(data)
  // Extract DEFLATE data (everything except last 8 bytes: CRC32 + ISIZE)
  let footer_start = data.length() - 8
  if pos >= footer_start {
    raise GzipError::UnexpectedEOF
  }
  let deflate_data = Bytes::makei(footer_start - pos, fn(i) { data[pos + i] })
  // Decompress DEFLATE data
  let decompressed = @flate.decompress(deflate_data) catch {
    e => raise GzipError::DeflateError(e.to_string())
  }
  // Verify CRC-32 (4 bytes LE)
  let expected_crc = data.unsafe_read_uint32_le(footer_start)
  let actual_crc = @checksum.crc32(decompressed[:])
  if actual_crc != expected_crc {
    raise GzipError::ChecksumMismatch(expected=expected_crc, got=actual_crc)
  }
  // Verify ISIZE (4 bytes LE) - original size mod 2^32
  let expected_size = data.unsafe_read_uint32_le(footer_start + 4)
  let actual_size = decompressed.length().reinterpret_as_uint() & 0xFFFFFFFF_U
  if actual_size != expected_size {
    raise GzipError::SizeMismatch(expected=expected_size, got=actual_size)
  }
  (decompressed, header)
}

///|
/// Parse gzip header. Returns (data_start_pos, header).
fn parse_gzip_header(data : Bytes) -> (Int, Header) raise GzipError {
  if data[0] != GZIP_MAGIC1 || data[1] != GZIP_MAGIC2 {
    raise GzipError::InvalidHeader("invalid gzip magic bytes")
  }
  if data[2] != GZIP_DEFLATE {
    raise GzipError::InvalidHeader("unsupported compression method \{data[2]}")
  }
  let flg = data[3].to_int()
  let mtime = data.unsafe_read_uint32_le(4)
  let os = data[9]
  let mut pos = 10
  // FEXTRA
  let mut extra = Bytes::default()
  if (flg & GZIP_FEXTRA) != 0 {
    if pos + 2 > data.length() {
      raise GzipError::UnexpectedEOF
    }
    let xlen = data[pos].to_int() | (data[pos + 1].to_int() << 8)
    pos += 2
    if pos + xlen > data.length() {
      raise GzipError::UnexpectedEOF
    }
    extra = Bytes::makei(xlen, fn(i) { data[pos + i] })
    pos += xlen
  }
  // FNAME
  let mut name = ""
  if (flg & GZIP_FNAME) != 0 {
    let sb = StringBuilder::new()
    while pos < data.length() && data[pos] != b'\x00' {
      sb.write_char(data[pos].to_int().unsafe_to_char())
      pos += 1
    }
    if pos >= data.length() {
      raise GzipError::UnexpectedEOF
    }
    pos += 1 // skip null terminator
    name = sb.to_string()
  }
  // FCOMMENT
  let mut comment = ""
  if (flg & GZIP_FCOMMENT) != 0 {
    let sb = StringBuilder::new()
    while pos < data.length() && data[pos] != b'\x00' {
      sb.write_char(data[pos].to_int().unsafe_to_char())
      pos += 1
    }
    if pos >= data.length() {
      raise GzipError::UnexpectedEOF
    }
    pos += 1
    comment = sb.to_string()
  }
  // FHCRC
  if (flg & GZIP_FHCRC) != 0 {
    if pos + 2 > data.length() {
      raise GzipError::UnexpectedEOF
    }
    pos += 2
  }
  (pos, Header::{ name, comment, extra, mod_time: mtime, os })
}
