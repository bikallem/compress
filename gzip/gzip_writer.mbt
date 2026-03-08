///|
/// GzipStreamWriter compresses data using gzip format and pushes to a dest `@stream.Writer`.
///
/// Implements `@stream.Writer` — push-based, accepts BytesView chunks.
/// True streaming: writes header on first chunk, compresses incrementally,
/// writes CRC32 + ISIZE trailer on EOD.
pub struct GzipStreamWriter {
  priv dest : &@stream.Writer
  priv deflater : @flate.DeflateWriter
  priv level : @flate.CompressionLevel
  priv header : Header
  priv crc : @checksum.CRC32
  priv mut size : UInt
  priv mut header_written : Bool
  priv mut closed : Bool
}

///|
pub fn GzipStreamWriter::new(
  dest : &@stream.Writer,
  level? : @flate.CompressionLevel = DefaultCompression,
  header? : Header = { ..Header::default() },
) -> GzipStreamWriter {
  {
    dest,
    deflater: @flate.DeflateWriter::new(dest, level~, forward_eod=false),
    level,
    header,
    crc: @checksum.CRC32::new(),
    size: 0U,
    header_written: false,
    closed: false,
  }
}

///|
fn GzipStreamWriter::write_header(
  self : GzipStreamWriter,
) -> Unit raise @stream.StreamError {
  let header = self.header
  let level = self.level
  let hdr = FixedArray::make(10, b'\x00')
  hdr[0] = GZIP_MAGIC1
  hdr[1] = GZIP_MAGIC2
  hdr[2] = GZIP_DEFLATE
  let mut flg = 0
  if header.name.length() > 0 {
    flg = flg | GZIP_FNAME
  }
  if header.comment.length() > 0 {
    flg = flg | GZIP_FCOMMENT
  }
  if header.extra.length() > 0 {
    flg = flg | GZIP_FEXTRA
  }
  hdr[3] = flg.to_byte()
  hdr[4] = (header.mod_time & 0xFFU).to_byte()
  hdr[5] = ((header.mod_time >> 8) & 0xFFU).to_byte()
  hdr[6] = ((header.mod_time >> 16) & 0xFFU).to_byte()
  hdr[7] = ((header.mod_time >> 24) & 0xFFU).to_byte()
  let xfl : Byte = match level {
    BestCompression => 2
    BestSpeed => 4
    _ => 0
  }
  hdr[8] = xfl
  hdr[9] = header.os
  self.dest.write(hdr.unsafe_reinterpret_as_bytes()[:10])
  // FEXTRA
  if header.extra.length() > 0 {
    let xlen = header.extra.length()
    let xhdr : FixedArray[Byte] = [
      (xlen & 0xFF).to_byte(),
      (xlen >> 8).to_byte(),
    ]
    self.dest.write(xhdr.unsafe_reinterpret_as_bytes()[:2])
    self.dest.write(header.extra[:])
  }
  // FNAME (Latin-1 + null terminator)
  if header.name.length() > 0 {
    let buf = FixedArray::make(header.name.iter().count() + 1, b'\x00')
    let mut j = 0
    for c in header.name {
      buf[j] = (c.to_int() & 0xFF).to_byte()
      j += 1
    }
    // buf[j] is already 0 (null terminator)
    self.dest.write(buf.unsafe_reinterpret_as_bytes()[:j + 1])
  }
  // FCOMMENT (Latin-1 + null terminator)
  if header.comment.length() > 0 {
    let buf = FixedArray::make(header.comment.iter().count() + 1, b'\x00')
    let mut j = 0
    for c in header.comment {
      buf[j] = (c.to_int() & 0xFF).to_byte()
      j += 1
    }
    self.dest.write(buf.unsafe_reinterpret_as_bytes()[:j + 1])
  }
  self.header_written = true
}

///|
pub impl @stream.Writer for GzipStreamWriter with write(self, data) {
  if data.is_empty() {
    if not(self.closed) {
      self.closed = true
      if not(self.header_written) {
        self.write_header()
      }
      // Signal EOD to deflater (writes final DEFLATE block)
      self.deflater.write(b""[:])
      // Write CRC32 + ISIZE trailer (8 bytes LE)
      let crc = self.crc.checksum()
      let isize = self.size
      let trailer : FixedArray[Byte] = [
        (crc & 0xFFU).to_byte(),
        ((crc >> 8) & 0xFFU).to_byte(),
        ((crc >> 16) & 0xFFU).to_byte(),
        ((crc >> 24) & 0xFFU).to_byte(),
        (isize & 0xFFU).to_byte(),
        ((isize >> 8) & 0xFFU).to_byte(),
        ((isize >> 16) & 0xFFU).to_byte(),
        ((isize >> 24) & 0xFFU).to_byte(),
      ]
      self.dest.write(trailer.unsafe_reinterpret_as_bytes()[:8])
      // Forward EOD
      self.dest.write(b""[:])
    }
    return
  }
  if not(self.header_written) {
    self.write_header()
  }
  // Update checksum and size incrementally
  self.crc.update(data)
  self.size = (self.size + data.length().reinterpret_as_uint()) & 0xFFFFFFFF_U
  // Forward to deflater
  self.deflater.write(data)
}
