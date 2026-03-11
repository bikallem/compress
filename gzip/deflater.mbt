///|
/// Streaming gzip compressor using signal protocol.
///
/// Wraps @flate.Deflater with gzip header (RFC 1952) and CRC-32/ISIZE trailer.
priv struct DeflaterState {
  deflater : @flate.Deflater
  crc : @checksum.CRC32
  mut size : UInt
  header : Bytes
  mut header_emitted : Bool
  mut finished : Bool
}

///|
struct Deflater(DeflaterState)

///|
pub fn Deflater::new(
  level? : @flate.CompressionLevel = DefaultCompression,
  header? : Header = { ..Header::default() },
) -> Deflater {
  Deflater({
    deflater: @flate.Deflater::new(level~),
    crc: @checksum.CRC32::new(),
    size: 0U,
    header: build_gzip_header(header, level),
    header_emitted: false,
    finished: false,
  })
}

///|
pub fn Deflater::encode(self : Deflater, data : Bytes?) -> Encode {
  let s = self.0
  if s.finished {
    return End
  }
  match data {
    Some(input) => {
      s.crc.update(input[:])
      s.size = (s.size + input.length().reinterpret_as_uint()) & 0xFFFFFFFF_U
      match s.deflater.encode(Some(input)) {
        Ok =>
          if not(s.header_emitted) {
            s.header_emitted = true
            Data(s.header)
          } else {
            Ok
          }
        Data(out) =>
          if not(s.header_emitted) {
            s.header_emitted = true
            Data(concat_bytes(s.header, out))
          } else {
            Data(out)
          }
        End => End
        Error(e) => Error(GzipError::DeflateError(e.to_string()))
      }
    }
    None =>
      match s.deflater.encode(None) {
        Data(out) =>
          if not(s.header_emitted) {
            s.header_emitted = true
            Data(concat_bytes(s.header, out))
          } else {
            Data(out)
          }
        End => {
          s.finished = true
          let trailer = gzip_trailer(s.crc.checksum(), s.size)
          if not(s.header_emitted) {
            s.header_emitted = true
            Data(concat_bytes(s.header, trailer))
          } else {
            Data(trailer)
          }
        }
        Ok => Ok
        Error(e) => Error(GzipError::DeflateError(e.to_string()))
      }
  }
}

///|
fn gzip_trailer(crc : UInt, size : UInt) -> Bytes {
  // 8 bytes: CRC32 (LE) + ISIZE (LE)
  Bytes::makei(8, fn(i) {
    if i < 4 {
      ((crc >> (i * 8)) & 0xFFU).to_byte()
    } else {
      ((size >> ((i - 4) * 8)) & 0xFFU).to_byte()
    }
  })
}

///|
fn concat_bytes(a : Bytes, b : Bytes) -> Bytes {
  if a.length() == 0 {
    return b
  }
  if b.length() == 0 {
    return a
  }
  let alen = a.length()
  Bytes::makei(alen + b.length(), fn(i) {
    if i < alen {
      a[i]
    } else {
      b[i - alen]
    }
  })
}
