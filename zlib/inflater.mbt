///|
/// Streaming zlib decompressor using signal protocol.
///
/// Wraps @flate2.Inflater with zlib header parsing and Adler-32 verification.
///
/// Usage:
///   let d = Inflater::new()
///   loop d.decode() {
///     Await => { d.src(chunk); continue d.decode() }
///     Data(out) => { write(out); continue d.decode() }
///     End => break
///     Error(e) => ...
///   }
priv struct InflaterState {
  inflater : @flate2.Inflater
  adler : @checksum.Adler32
  dict : Bytes
  mut phase : InflatePhase
  // Header accumulator — collects bytes until header is parsed
  hdr_buf : @buffer.Buffer
}

///|
priv enum InflatePhase {
  ParseHeader
  Inflate
  VerifyTrailer(Bytes) // remaining bytes from inflater
  Done
  Failed(ZlibError)
}

///|
struct Inflater(InflaterState)

///|
pub fn Inflater::new(dict? : Bytes = Bytes::default()) -> Inflater {
  let inflater = if dict.length() > 0 {
    @flate2.Inflater::new(dict~)
  } else {
    @flate2.Inflater::new()
  }
  Inflater({
    inflater,
    adler: @checksum.Adler32::new(),
    dict,
    phase: ParseHeader,
    hdr_buf: @buffer.new(),
  })
}

///|
pub fn Inflater::src(self : Inflater, data : Bytes) -> Unit {
  let s = self.0
  match s.phase {
    ParseHeader => {
      s.hdr_buf.write_bytes(data)
      // Try to parse header from accumulated bytes
      let buf = s.hdr_buf.to_bytes()
      match try_parse_header_bytes(buf, s.dict) {
        Ok((header_len, _fdict)) => {
          // Feed all remaining bytes after header to inflater in one call
          let remaining_len = buf.length() - header_len
          if remaining_len > 0 {
            let remaining = Bytes::makei(remaining_len, fn(i) {
              buf[header_len + i]
            })
            s.inflater.src(remaining)
          }
          s.phase = Inflate
        }
        Err(NeedMore) => () // wait for more data
        Err(HeaderError(e)) => s.phase = Failed(e)
      }
    }
    Inflate => s.inflater.src(data)
    VerifyTrailer(prev) => {
      // Accumulate trailer bytes from new chunk
      let combined = Bytes::makei(prev.length() + data.length(), fn(i) {
        if i < prev.length() { prev[i] } else { data[i - prev.length()] }
      })
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
        @flate2.Await => Await
        @flate2.Data(out) => {
          s.adler.update(out[:])
          Data(out)
        }
        @flate2.End => {
          let remaining = s.inflater.remaining()
          verify_trailer(s, remaining)
        }
        @flate2.Error(e) =>
          fail_with(s, ZlibError::DeflateError(e.to_string()))
      }
    VerifyTrailer(remaining) => verify_trailer(s, remaining)
    Done => End
    Failed(e) => Error(e)
  }
}

///|
priv enum HeaderParseResult {
  NeedMore
  HeaderError(ZlibError)
}

///|
fn try_parse_header_bytes(
  data : Bytes,
  dict : Bytes,
) -> Result[(Int, Bool), HeaderParseResult] {
  if data.length() < 2 {
    return Err(NeedMore)
  }
  let cmf = data[0].to_int()
  let flg = data[1].to_int()
  if (cmf * 256 + flg) % 31 != 0 {
    return Err(
      HeaderError(ZlibError::InvalidHeader("invalid zlib header checksum")),
    )
  }
  let cm = cmf & 0x0F
  if cm != ZLIB_DEFLATE_METHOD {
    return Err(
      HeaderError(
        ZlibError::InvalidHeader("unsupported compression method \{cm}"),
      ),
    )
  }
  let cinfo = (cmf >> 4) & 0x0F
  if cinfo > 7 {
    return Err(
      HeaderError(
        ZlibError::InvalidHeader("invalid window size \{cinfo}"),
      ),
    )
  }
  let fdict = (flg >> 5) & 1
  if fdict != 0 {
    if data.length() < 6 {
      return Err(NeedMore)
    }
    let dict_id = (data[2].to_uint() << 24) |
      (data[3].to_uint() << 16) |
      (data[4].to_uint() << 8) |
      data[5].to_uint()
    if dict.length() == 0 {
      return Err(HeaderError(ZlibError::NeedDictionary(dict_id)))
    }
    let actual_dict_id = @checksum.adler32(dict[:])
    if actual_dict_id != dict_id {
      return Err(
        HeaderError(
          ZlibError::InvalidHeader("dictionary checksum mismatch"),
        ),
      )
    }
    Ok((6, true))
  } else {
    Ok((2, false))
  }
}

///|
fn verify_trailer(s : InflaterState, remaining : Bytes) -> Decode {
  if remaining.length() < 4 {
    s.phase = VerifyTrailer(remaining)
    return Await
  }
  let expected = (remaining[0].to_uint() << 24) |
    (remaining[1].to_uint() << 16) |
    (remaining[2].to_uint() << 8) |
    remaining[3].to_uint()
  let actual = s.adler.checksum()
  if actual != expected {
    fail_with(s, ZlibError::ChecksumMismatch(expected~, got=actual))
  } else {
    s.phase = Done
    End
  }
}

///|
fn fail_with(s : InflaterState, e : ZlibError) -> Decode {
  s.phase = Failed(e)
  Error(e)
}
