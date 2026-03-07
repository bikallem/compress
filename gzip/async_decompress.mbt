///|
/// Streaming decompression of gzip data from a reader to a writer.
/// Returns the parsed gzip header.
pub async fn decompress_to(source : &@io.Reader, dest : &@io.Writer) -> Header {
  // Read 10-byte header
  let hdr = source.read_exactly(10)
  if hdr[0] != GZIP_MAGIC1 || hdr[1] != GZIP_MAGIC2 {
    raise GzipError::InvalidHeader("invalid gzip magic bytes")
  }
  if hdr[2] != GZIP_DEFLATE {
    raise GzipError::InvalidHeader("unsupported compression method \{hdr[2]}")
  }
  let flg = hdr[3].to_int()
  let mtime = hdr[4].to_uint() |
    (hdr[5].to_uint() << 8) |
    (hdr[6].to_uint() << 16) |
    (hdr[7].to_uint() << 24)
  let os = hdr[9]
  // FEXTRA
  let mut extra = Bytes::default()
  if (flg & GZIP_FEXTRA) != 0 {
    let xlen_bytes = source.read_exactly(2)
    let xlen = xlen_bytes[0].to_int() | (xlen_bytes[1].to_int() << 8)
    extra = source.read_exactly(xlen)
  }
  // FNAME
  let mut name = ""
  if (flg & GZIP_FNAME) != 0 {
    let name_buf = @buffer.new()
    while true {
      let b = source.read_exactly(1)
      if b[0] == b'\x00' {
        break
      }
      name_buf.write_byte(b[0])
    }
    let name_bytes = name_buf.to_bytes()
    let sb = StringBuilder::new()
    for i in 0..<name_bytes.length() {
      sb.write_char(name_bytes[i].to_int().unsafe_to_char())
    }
    name = sb.to_string()
  }
  // FCOMMENT
  let mut comment = ""
  if (flg & GZIP_FCOMMENT) != 0 {
    let comment_buf = @buffer.new()
    while true {
      let b = source.read_exactly(1)
      if b[0] == b'\x00' {
        break
      }
      comment_buf.write_byte(b[0])
    }
    let comment_bytes = comment_buf.to_bytes()
    let sb = StringBuilder::new()
    for i in 0..<comment_bytes.length() {
      sb.write_char(comment_bytes[i].to_int().unsafe_to_char())
    }
    comment = sb.to_string()
  }
  // FHCRC
  if (flg & GZIP_FHCRC) != 0 {
    ignore(source.read_exactly(2))
  }
  // Decompress DEFLATE stream, tracking CRC32 and size
  let crc_writer = ChecksumWriter::new(dest)
  let remaining = @flate.decompress_to(source, crc_writer)
  // Read 8-byte footer: CRC32 (4 LE) + ISIZE (4 LE)
  let footer = read_footer(remaining, source, 8)
  let expected_crc = footer[0].to_uint() |
    (footer[1].to_uint() << 8) |
    (footer[2].to_uint() << 16) |
    (footer[3].to_uint() << 24)
  let actual_crc = crc_writer.crc.checksum()
  if actual_crc != expected_crc {
    raise GzipError::ChecksumMismatch(expected=expected_crc, got=actual_crc)
  }
  let expected_size = footer[4].to_uint() |
    (footer[5].to_uint() << 8) |
    (footer[6].to_uint() << 16) |
    (footer[7].to_uint() << 24)
  let actual_size = crc_writer.size & 0xFFFFFFFF_U
  if actual_size != expected_size {
    raise GzipError::SizeMismatch(expected=expected_size, got=actual_size)
  }
  { name, comment, extra, mod_time: mtime, os }
}

///|
/// Reads exactly `n` bytes, first from `remaining` then from `source`.
async fn read_footer(remaining : Bytes, source : &@io.Reader, n : Int) -> Bytes {
  if remaining.length() >= n {
    return remaining
  }
  let buf = @buffer.new(size_hint=n)
  for i in 0..<remaining.length() {
    buf.write_byte(remaining[i])
  }
  let need = n - remaining.length()
  let extra = source.read_exactly(need)
  for i in 0..<extra.length() {
    buf.write_byte(extra[i])
  }
  buf.to_bytes()
}

///|
/// Writer wrapper that computes CRC-32 and tracks byte count.
priv struct ChecksumWriter {
  dest : &@io.Writer
  crc : @checksum.CRC32
  mut size : UInt
}

///|
fn ChecksumWriter::new(dest : &@io.Writer) -> ChecksumWriter {
  { dest, crc: @checksum.CRC32::new(), size: 0U }
}

///|
impl @io.Writer for ChecksumWriter with write_once(self, bytes, offset~, len~) {
  let written = self.dest.write_once(bytes, offset~, len~)
  self.crc.update(bytes[offset:offset + written])
  self.size += written.reinterpret_as_uint()
  written
}
