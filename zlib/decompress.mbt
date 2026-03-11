///|
/// Decompresses zlib-encoded data (RFC 1950).
pub fn decompress(data : Bytes) -> Bytes raise ZlibError {
  decompress_with_dict(data, Bytes::default())
}

///|
/// Decompresses zlib-encoded data with a preset dictionary.
pub fn decompress_with_dict(
  data : Bytes,
  dict : Bytes,
) -> Bytes raise ZlibError {
  // Need at least 2 bytes header + 4 bytes Adler-32 footer
  if data.length() < 6 {
    raise ZlibError::UnexpectedEOF
  }
  let (data_start, _) = parse_zlib_header(data, dict)
  // Extract the DEFLATE data (everything except last 4 bytes which are Adler-32)
  let deflate_end = data.length() - 4
  if data_start >= deflate_end {
    raise ZlibError::UnexpectedEOF
  }
  let deflate_data = Bytes::makei(deflate_end - data_start, fn(i) {
    data[data_start + i]
  })
  // Decompress DEFLATE data
  let decompressed = try {
    if dict.length() > 0 {
      @flate.decompress_with_dict(deflate_data, dict)
    } else {
      @flate.decompress(deflate_data)
    }
  } catch {
    e => raise ZlibError::DeflateError(e.to_string())
  }
  // Verify Adler-32 checksum (big-endian in footer)
  let expected_checksum = read_uint32_be(data, deflate_end)
  let actual_checksum = @checksum.adler32(decompressed[:])
  if actual_checksum != expected_checksum {
    raise ZlibError::ChecksumMismatch(
      expected=expected_checksum,
      got=actual_checksum,
    )
  }
  decompressed
}

///|
/// Parse zlib header. Returns (data_start_offset, fdict_present).
fn parse_zlib_header(data : Bytes, dict : Bytes) -> (Int, Bool) raise ZlibError {
  let cmf = data[0].to_int()
  let flg = data[1].to_int()
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
  let mut data_start = 2
  if fdict != 0 {
    if data.length() < 10 {
      raise ZlibError::UnexpectedEOF
    }
    let dict_id = read_uint32_be(data, 2)
    data_start = 6
    if dict.length() == 0 {
      raise ZlibError::NeedDictionary(dict_id)
    }
    let actual_dict_id = @checksum.adler32(dict[:])
    if actual_dict_id != dict_id {
      raise ZlibError::InvalidHeader("dictionary checksum mismatch")
    }
  }
  (data_start, fdict != 0)
}

///|
fn read_uint32_be(data : Bytes, offset : Int) -> UInt {
  (data[offset].to_uint() << 24) |
  (data[offset + 1].to_uint() << 16) |
  (data[offset + 2].to_uint() << 8) |
  data[offset + 3].to_uint()
}
