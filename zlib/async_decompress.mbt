///|
/// Streaming decompression of zlib data from a reader to a writer.
pub async fn decompress_to(source : &@io.Reader, dest : &@io.Writer) -> Unit {
  decompress_to_with_dict(source, dest, Bytes::default())
}

///|
/// Streaming decompression of zlib data with a preset dictionary.
pub async fn decompress_to_with_dict(
  source : &@io.Reader,
  dest : &@io.Writer,
  dict : Bytes,
) -> Unit {
  // Read 2-byte header
  let header = source.read_exactly(2)
  let cmf = header[0].to_int()
  let flg = header[1].to_int()
  if (cmf * 256 + flg) % 31 != 0 {
    raise ZlibError::InvalidHeader("invalid zlib header checksum")
  }
  let cm = cmf & 0x0F
  if cm != ZLIB_DEFLATE_METHOD {
    raise ZlibError::InvalidHeader("unsupported compression method \{cm}")
  }
  let cinfo = (cmf >> 4) & 0x0F
  if cinfo > 7 {
    raise ZlibError::InvalidHeader("invalid window size \{cinfo}")
  }
  let fdict = (flg >> 5) & 1
  if fdict != 0 {
    let dict_id_bytes = source.read_exactly(4)
    let dict_id = (dict_id_bytes[0].to_uint() << 24) |
      (dict_id_bytes[1].to_uint() << 16) |
      (dict_id_bytes[2].to_uint() << 8) |
      dict_id_bytes[3].to_uint()
    if dict.length() == 0 {
      raise ZlibError::NeedDictionary(dict_id)
    }
    let actual_dict_id = @checksum.adler32(dict[:])
    if actual_dict_id != dict_id {
      raise ZlibError::InvalidHeader("dictionary checksum mismatch")
    }
  }
  let adler_writer = Adler32Writer::new(dest)
  // Decompress DEFLATE stream — returns unconsumed bytes from bit buffer
  let remaining = if dict.length() > 0 {
    @flate.decompress_to_with_dict(source, adler_writer, dict)
  } else {
    @flate.decompress_to(source, adler_writer)
  }
  // Read 4-byte Adler-32 footer, combining remaining bytes with source
  let footer = read_footer(remaining, source, 4)
  let expected_checksum = (footer[0].to_uint() << 24) |
    (footer[1].to_uint() << 16) |
    (footer[2].to_uint() << 8) |
    footer[3].to_uint()
  let actual_checksum = adler_writer.checksum()
  if actual_checksum != expected_checksum {
    raise ZlibError::ChecksumMismatch(
      expected=expected_checksum,
      got=actual_checksum,
    )
  }
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
/// Writer wrapper that computes Adler-32 checksum on the fly.
priv struct Adler32Writer {
  dest : &@io.Writer
  mut s1 : UInt
  mut s2 : UInt
}

///|
fn Adler32Writer::new(dest : &@io.Writer) -> Adler32Writer {
  { dest, s1: 1U, s2: 0U }
}

///|
fn Adler32Writer::checksum(self : Adler32Writer) -> UInt {
  (self.s2 << 16) | self.s1
}

///|
impl @io.Writer for Adler32Writer with write_once(self, bytes, offset~, len~) {
  let written = self.dest.write_once(bytes, offset~, len~)
  for i in offset..<(offset + written) {
    self.s1 = (self.s1 + bytes[i].to_uint()) % 65521U
    self.s2 = (self.s2 + self.s1) % 65521U
  }
  written
}
