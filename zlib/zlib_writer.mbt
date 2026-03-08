///|
/// ZlibStreamWriter compresses data using zlib format and pushes to a dest `@stream.Writer`.
///
/// Implements `@stream.Writer` — push-based, accepts BytesView chunks.
/// True streaming: writes header on first chunk, compresses incrementally,
/// writes Adler-32 trailer on EOD.
pub struct ZlibStreamWriter {
  priv dest : &@stream.Writer
  priv deflater : @flate.DeflateWriter
  priv level : @flate.CompressionLevel
  priv dict : Bytes
  priv adler : @checksum.Adler32
  priv mut header_written : Bool
  priv mut closed : Bool
}

///|
pub fn ZlibStreamWriter::new(
  dest : &@stream.Writer,
  level? : @flate.CompressionLevel = DefaultCompression,
  dict? : Bytes = Bytes::default(),
) -> ZlibStreamWriter {
  {
    dest,
    deflater: @flate.DeflateWriter::new(dest, level~, dict~, forward_eod=false),
    level,
    dict,
    adler: @checksum.Adler32::new(),
    header_written: false,
    closed: false,
  }
}

///|
fn ZlibStreamWriter::write_header(
  self : ZlibStreamWriter,
) -> Unit raise @stream.StreamError {
  let cmf = (ZLIB_DEFAULT_CINFO << 4) | ZLIB_DEFLATE_METHOD
  let flevel = match self.level {
    NoCompression | HuffmanOnly => 0
    BestSpeed | Level(1) | Level(2) => 1
    Level(n) => if n <= 5 { 1 } else { 2 }
    BestCompression => 3
    DefaultCompression => 2
  }
  let fdict = if self.dict.length() > 0 { 1 } else { 0 }
  let mut flg = (flevel << 6) | (fdict << 5)
  let remainder = (cmf * 256 + flg) % 31
  if remainder != 0 {
    flg += 31 - remainder
  }
  let hdr : FixedArray[Byte] = [cmf.to_byte(), flg.to_byte()]
  self.dest.write(hdr.unsafe_reinterpret_as_bytes()[:2])
  // Write DICTID if dictionary provided
  if self.dict.length() > 0 {
    let dict_checksum = @checksum.adler32(self.dict[:])
    let dhdr : FixedArray[Byte] = [
      ((dict_checksum >> 24) & 0xFFU).to_byte(),
      ((dict_checksum >> 16) & 0xFFU).to_byte(),
      ((dict_checksum >> 8) & 0xFFU).to_byte(),
      (dict_checksum & 0xFFU).to_byte(),
    ]
    self.dest.write(dhdr.unsafe_reinterpret_as_bytes()[:4])
  }
  self.header_written = true
}

///|
pub impl @stream.Writer for ZlibStreamWriter with write(self, data) {
  if data.is_empty() {
    if not(self.closed) {
      self.closed = true
      if not(self.header_written) {
        self.write_header()
      }
      // Signal EOD to deflater (writes final DEFLATE block)
      self.deflater.write(b""[:])
      // Write Adler-32 checksum (big-endian)
      let checksum = self.adler.checksum()
      let trailer : FixedArray[Byte] = [
        ((checksum >> 24) & 0xFFU).to_byte(),
        ((checksum >> 16) & 0xFFU).to_byte(),
        ((checksum >> 8) & 0xFFU).to_byte(),
        (checksum & 0xFFU).to_byte(),
      ]
      self.dest.write(trailer.unsafe_reinterpret_as_bytes()[:4])
      // Forward EOD
      self.dest.write(b""[:])
    }
    return
  }
  if not(self.header_written) {
    self.write_header()
  }
  // Update checksum incrementally
  self.adler.update(data)
  // Forward to deflater
  self.deflater.write(data)
}
