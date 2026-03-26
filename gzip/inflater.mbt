///|
/// Streaming gzip decompressor using signal protocol.
///
/// Wraps @flate.Inflater with gzip header parsing and CRC-32/ISIZE verification.
priv struct Decoder {
  mut inflater : @flate.Inflater
  crc : @checksum.CRC32
  mut size : UInt
  mut phase : InflatePhase
  mut input_finished : Bool
  // Header accumulator
  mut hdr_buf : @blit.Buffer
  mut header : Header
  headers : Array[Header]
}

///|
priv enum InflatePhase {
  ParseHeader
  Inflate
  VerifyTrailer(Bytes) // remaining bytes waiting for 8-byte trailer
  AwaitNextMember
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
    input_finished: false,
    hdr_buf: @blit.Buffer::new(),
    header: Header::default(),
    headers: [],
  })
}

///|
/// Returns the parsed gzip header. Only valid after decoding has started.
pub fn Inflater::header(self : Inflater) -> Header {
  self.0.header
}

///|
/// Returns all parsed member headers in decode order.
pub fn Inflater::member_headers(self : Inflater) -> Array[Header] {
  let headers = self.0.headers
  Array::makei(headers.length(), fn(i) { headers[i] })
}

///|
pub fn Inflater::src(self : Inflater, data : BytesView) -> Unit {
  let s = self.0
  if data.length() > 0 {
    s.input_finished = false
  }
  match s.phase {
    ParseHeader => {
      s.hdr_buf.write_bytesview(data)
      pump_header(s)
    }
    Inflate => s.inflater.src(data)
    VerifyTrailer(prev) => {
      let combined = prev + data.to_bytes()
      s.phase = VerifyTrailer(combined)
    }
    AwaitNextMember =>
      if data.length() > 0 {
        reset_for_next_member(s, data)
        pump_header(s)
      }
    Done | Failed(_) => ()
  }
}

///|
/// Marks the compressed input as complete.
///
/// Call this once the upstream source reaches EOF so the inflater can
/// distinguish a true end-of-input from an exact boundary between
/// concatenated gzip members.
pub fn Inflater::finish(self : Inflater) -> Unit {
  self.0.input_finished = true
}

///|
pub fn Inflater::decode(self : Inflater) -> Decode {
  let s = self.0
  for ;; {
    match s.phase {
      ParseHeader => {
        pump_header(s)
        match s.phase {
          ParseHeader =>
            return if s.input_finished {
              fail_with(s, GzipError::UnexpectedEOF)
            } else {
              Await
            }
          Failed(e) => return Error(e)
          _ => continue
        }
      }
      Inflate =>
        match s.inflater.decode() {
          @flate.Await =>
            return if s.input_finished {
              fail_with(s, GzipError::UnexpectedEOF)
            } else {
              Await
            }
          @flate.Data(out) => {
            s.crc.update(out)
            s.size = (s.size + out.length().reinterpret_as_uint()) &
              0xFFFFFFFF_U
            return Data(out)
          }
          @flate.End => {
            let remaining = s.inflater.remaining()
            match verify_gzip_trailer(s, remaining) {
              Some(result) => return result
              None => continue
            }
          }
          @flate.Error(e) =>
            return fail_with(s, GzipError::DeflateError(e.to_string()))
        }
      VerifyTrailer(remaining) =>
        match verify_gzip_trailer(s, remaining) {
          Some(result) => return result
          None => continue
        }
      AwaitNextMember =>
        return if s.input_finished {
          s.phase = Done
          End
        } else {
          Await
        }
      Done => return End
      Failed(e) => return Error(e)
    }
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
  if (flg & GZIP_RESERVED_FLAGS) != 0 {
    return Err(
      HeaderError(
        GzipError::InvalidHeader("reserved gzip header flags are set"),
      ),
    )
  }
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
    let expected_hcrc = data[pos].to_uint() | (data[pos + 1].to_uint() << 8)
    let actual_hcrc = gzip_header_crc16(data[:], pos)
    if actual_hcrc != expected_hcrc {
      return Err(
        HeaderError(GzipError::InvalidHeader("header checksum mismatch")),
      )
    }
    pos += 2
  }
  Ok((pos, Header::{ name, comment, extra, mod_time: mtime, os }))
}

///|
fn verify_gzip_trailer(s : Decoder, remaining : Bytes) -> Decode? {
  if remaining.length() < 8 {
    if s.input_finished {
      return Some(fail_with(s, GzipError::UnexpectedEOF))
    }
    s.phase = VerifyTrailer(remaining)
    return Some(Await)
  }
  let expected_crc = remaining[0].to_uint() |
    (remaining[1].to_uint() << 8) |
    (remaining[2].to_uint() << 16) |
    (remaining[3].to_uint() << 24)
  let actual_crc = s.crc.checksum()
  if actual_crc != expected_crc {
    return Some(
      fail_with(
        s,
        GzipError::ChecksumMismatch(expected=expected_crc, got=actual_crc),
      ),
    )
  }
  let expected_size = remaining[4].to_uint() |
    (remaining[5].to_uint() << 8) |
    (remaining[6].to_uint() << 16) |
    (remaining[7].to_uint() << 24)
  if s.size != expected_size {
    return Some(
      fail_with(s, GzipError::SizeMismatch(expected=expected_size, got=s.size)),
    )
  }
  let trailing = remaining[8:]
  if trailing.length() > 0 {
    reset_for_next_member(s, trailing)
    return None
  }
  if s.input_finished {
    s.phase = Done
    return Some(End)
  }
  s.phase = AwaitNextMember
  Some(Await)
}

///|
fn pump_header(s : Decoder) -> Unit {
  let buf = s.hdr_buf.to_bytes()
  match try_parse_gzip_header(buf) {
    Ok((pos, header)) => {
      s.header = header
      s.headers.push(header)
      s.inflater = @flate.Inflater::new()
      let remaining_len = buf.length() - pos
      if remaining_len > 0 {
        s.inflater.src(buf[pos:])
      }
      s.hdr_buf = @blit.Buffer::new()
      s.phase = Inflate
    }
    Err(NeedMore) => ()
    Err(HeaderError(e)) => s.phase = Failed(e)
  }
}

///|
fn reset_for_next_member(s : Decoder, trailing : BytesView) -> Unit {
  s.crc.reset()
  s.size = 0U
  s.inflater = @flate.Inflater::new()
  s.hdr_buf = @blit.Buffer::new(size_hint=trailing.length())
  if trailing.length() > 0 {
    s.hdr_buf.write_bytesview(trailing)
  }
  s.phase = ParseHeader
}

///|
fn fail_with(s : Decoder, e : GzipError) -> Decode {
  s.phase = Failed(e)
  Error(e)
}
