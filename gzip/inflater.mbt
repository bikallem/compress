///|
/// Streaming gzip decompressor using signal protocol.
///
/// Wraps @flate.Inflater with gzip header parsing and CRC-32/ISIZE verification.
priv struct Decoder {
  inflater : @flate.Inflater
  crc : @checksum.CRC32
  mut size : UInt
  mut phase : InflatePhase
  // Header accumulator
  hdr_buf : @buffer.Buffer
  mut header : Header
}

///|
priv enum InflatePhase {
  ParseHeader
  Inflate
  VerifyTrailer(Bytes) // remaining bytes waiting for 8-byte trailer
  Done
  Failed(GzipError)
}

///|
struct Inflater(Decoder)

///|
pub fn Inflater::new() -> Inflater {
  Inflater({
    inflater: @flate.Inflater::new(),
    crc: @checksum.CRC32::new(),
    size: 0U,
    phase: ParseHeader,
    hdr_buf: @buffer.new(),
    header: Header::default(),
  })
}

///|
/// Returns the parsed gzip header. Only valid after decoding has started.
pub fn Inflater::header(self : Inflater) -> Header {
  self.0.header
}

///|
pub fn Inflater::src(self : Inflater, data : BytesView) -> Unit {
  let s = self.0
  match s.phase {
    ParseHeader => {
      s.hdr_buf.write_bytesview(data)
      // Try to parse header from accumulated bytes
      let buf = s.hdr_buf.to_bytes()
      match try_parse_gzip_header(buf) {
        Ok((pos, header)) => {
          s.header = header
          // Feed all remaining bytes after header to inflater in one call
          let remaining_len = buf.length() - pos
          if remaining_len > 0 {
            s.inflater.src(buf[pos:])
          }
          s.phase = Inflate
        }
        Err(NeedMore) => ()
        Err(HeaderError(e)) => s.phase = Failed(e)
      }
    }
    Inflate => s.inflater.src(data)
    VerifyTrailer(prev) => {
      let combined = prev + data.to_bytes()
      s.phase = VerifyTrailer(combined)
    }
    Done | Failed(_) => ()
  }
}

///|
pub fn Inflater::decode(self : Inflater) -> Decode {
  let s = self.0
  match s.phase {
    ParseHeader => Await
    Inflate =>
      match s.inflater.decode() {
        @flate.Await => Await
        @flate.Data(out) => {
          s.crc.update(out[:])
          s.size = (s.size + out.length().reinterpret_as_uint()) & 0xFFFFFFFF_U
          Data(out)
        }
        @flate.End => {
          let remaining = s.inflater.remaining()
          verify_gzip_trailer(s, remaining)
        }
        @flate.Error(e) => fail_with(s, GzipError::DeflateError(e.to_string()))
      }
    VerifyTrailer(remaining) => verify_gzip_trailer(s, remaining)
    Done => End
    Failed(e) => Error(e)
  }
}

///|
priv enum HeaderParseResult {
  NeedMore
  HeaderError(GzipError)
}

///|
fn try_parse_gzip_header(
  data : Bytes,
) -> Result[(Int, Header), HeaderParseResult] {
  if data.length() < 10 {
    return Err(NeedMore)
  }
  if data[0] != GZIP_MAGIC1 || data[1] != GZIP_MAGIC2 {
    return Err(
      HeaderError(GzipError::InvalidHeader("invalid gzip magic bytes")),
    )
  }
  if data[2] != GZIP_DEFLATE {
    return Err(
      HeaderError(
        GzipError::InvalidHeader("unsupported compression method \{data[2]}"),
      ),
    )
  }
  let flg = data[3].to_int()
  let mtime = data[4].to_uint() |
    (data[5].to_uint() << 8) |
    (data[6].to_uint() << 16) |
    (data[7].to_uint() << 24)
  let os = data[9]
  let mut pos = 10
  // FEXTRA
  let mut extra = Bytes::default()
  if (flg & GZIP_FEXTRA) != 0 {
    if pos + 2 > data.length() {
      return Err(NeedMore)
    }
    let xlen = data[pos].to_int() | (data[pos + 1].to_int() << 8)
    pos += 2
    if pos + xlen > data.length() {
      return Err(NeedMore)
    }
    extra = Bytes::makei(xlen, fn(i) { data[pos + i] })
    pos += xlen
  }
  // FNAME
  let mut name = ""
  if (flg & GZIP_FNAME) != 0 {
    let start = pos
    while pos < data.length() && data[pos] != b'\x00' {
      pos += 1
    }
    if pos >= data.length() {
      return Err(NeedMore)
    }
    let sb = StringBuilder::new()
    for i in start..<pos {
      sb.write_char(data[i].to_int().unsafe_to_char())
    }
    name = sb.to_string()
    pos += 1 // skip null
  }
  // FCOMMENT
  let mut comment = ""
  if (flg & GZIP_FCOMMENT) != 0 {
    let start = pos
    while pos < data.length() && data[pos] != b'\x00' {
      pos += 1
    }
    if pos >= data.length() {
      return Err(NeedMore)
    }
    let sb = StringBuilder::new()
    for i in start..<pos {
      sb.write_char(data[i].to_int().unsafe_to_char())
    }
    comment = sb.to_string()
    pos += 1
  }
  // FHCRC
  if (flg & GZIP_FHCRC) != 0 {
    if pos + 2 > data.length() {
      return Err(NeedMore)
    }
    pos += 2
  }
  Ok((pos, Header::{ name, comment, extra, mod_time: mtime, os }))
}

///|
fn verify_gzip_trailer(s : Decoder, remaining : Bytes) -> Decode {
  if remaining.length() < 8 {
    s.phase = VerifyTrailer(remaining)
    return Await
  } else {
    let expected_crc = remaining[0].to_uint() |
      (remaining[1].to_uint() << 8) |
      (remaining[2].to_uint() << 16) |
      (remaining[3].to_uint() << 24)
    let actual_crc = s.crc.checksum()
    if actual_crc != expected_crc {
      return fail_with(
        s,
        GzipError::ChecksumMismatch(expected=expected_crc, got=actual_crc),
      )
    }
    let expected_size = remaining[4].to_uint() |
      (remaining[5].to_uint() << 8) |
      (remaining[6].to_uint() << 16) |
      (remaining[7].to_uint() << 24)
    if s.size != expected_size {
      return fail_with(
        s,
        GzipError::SizeMismatch(expected=expected_size, got=s.size),
      )
    }
    s.phase = Done
    End
  }
}

///|
fn fail_with(s : Decoder, e : GzipError) -> Decode {
  s.phase = Failed(e)
  Error(e)
}
