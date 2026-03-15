///|
/// Streaming zlib compressor using signal protocol.
///
/// Wraps @flate.Deflater with zlib header (RFC 1950) and Adler-32 trailer.
///
/// Usage:
///   let d = Deflater::new()
///   loop {
///     match d.encode(Some(chunk)) { Ok => break; Data(out) => write(out); .. }
///   }
///   loop {
///     match d.encode(None) { Data(out) => write(out); End => break; .. }
///   }
priv struct Encoder {
  deflater : @flate.Deflater
  adler : @checksum.Adler32
  header : Bytes
  mut header_emitted : Bool
  mut finished : Bool
}

///|
struct Deflater(Encoder)

///|
pub fn Deflater::new(
  level? : @flate.CompressionLevel = DefaultCompression,
  dict? : Bytes = Bytes::default(),
) -> Deflater {
  let deflater = if dict.length() > 0 {
    @flate.Deflater::new(level~, dict~)
  } else {
    @flate.Deflater::new(level~)
  }
  Deflater({
    deflater,
    adler: @checksum.Adler32::new(),
    header: build_zlib_header(level, dict),
    header_emitted: false,
    finished: false,
  })
}

///|
pub fn Deflater::encode(self : Deflater, data : BytesView?) -> Encode {
  let s = self.0
  if s.finished {
    return End
  }
  match data {
    Some(input) => {
      s.adler.update(input[:])
      match s.deflater.encode(Some(input)) {
        Ok =>
          if !s.header_emitted {
            s.header_emitted = true
            Data(s.header)
          } else {
            Ok
          }
        Data(out) =>
          if !s.header_emitted {
            s.header_emitted = true
            Data(s.header + out)
          } else {
            Data(out)
          }
        End => End
        Error(e) => Error(ZlibError::DeflateError(e.to_string()))
      }
    }
    None =>
      match s.deflater.encode(None) {
        Data(out) =>
          if !s.header_emitted {
            s.header_emitted = true
            Data(s.header + out)
          } else {
            Data(out)
          }
        End => {
          s.finished = true
          let trailer = adler32_trailer(s.adler.checksum())
          if !s.header_emitted {
            s.header_emitted = true
            Data(s.header + trailer)
          } else {
            Data(trailer)
          }
        }
        Ok => Ok
        Error(e) => Error(ZlibError::DeflateError(e.to_string()))
      }
  }
}

///|
fn adler32_trailer(checksum : UInt) -> Bytes {
  Bytes::makei(4, fn(i) { ((checksum >> ((3 - i) * 8)) & 0xFFU).to_byte() })
}
