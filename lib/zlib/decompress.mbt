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
  // Parse header
  let cmf = data[0].to_int()
  let flg = data[1].to_int()
  // Check FCHECK: CMF*256 + FLG must be a multiple of 31
  if (cmf * 256 + flg) % 31 != 0 {
    raise ZlibError::InvalidHeader("invalid zlib header checksum")
  }
  // Check compression method (lower 4 bits of CMF must be 8 = deflate)
  let cm = cmf & 0x0F
  if cm != zlib_deflate_method {
    raise ZlibError::InvalidHeader("unsupported compression method \{cm}")
  }
  // Check CINFO (upper 4 bits of CMF) - window size must be <= 7
  let cinfo = (cmf >> 4) & 0x0F
  if cinfo > 7 {
    raise ZlibError::InvalidHeader("invalid window size \{cinfo}")
  }
  // Check for preset dictionary (FDICT bit 5 of FLG)
  let fdict = (flg >> 5) & 1
  let mut data_start = 2
  if fdict != 0 {
    if data.length() < 10 {
      raise ZlibError::UnexpectedEOF
    }
    // Read DICTID (4 bytes big-endian Adler-32 of dictionary)
    let dict_id = (data[2].to_uint() << 24) |
      (data[3].to_uint() << 16) |
      (data[4].to_uint() << 8) |
      data[5].to_uint()
    data_start = 6
    // Verify dict was provided and matches
    if dict.length() == 0 {
      raise ZlibError::NeedDictionary(dict_id)
    }
    let actual_dict_id = @checksum.adler32(dict[:])
    if actual_dict_id != dict_id {
      raise ZlibError::InvalidHeader("dictionary checksum mismatch")
    }
  }
  // Extract the DEFLATE data (everything except last 4 bytes which are Adler-32)
  let deflate_end = data.length() - 4
  if data_start >= deflate_end {
    raise ZlibError::UnexpectedEOF
  }
  // Build deflate data bytes
  let deflate_data_buf = @buffer.new(size_hint=deflate_end - data_start)
  for i in data_start..<deflate_end {
    deflate_data_buf.write_byte(data[i])
  }
  let deflate_data = deflate_data_buf.to_bytes()
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
  let expected_checksum = (data[deflate_end].to_uint() << 24) |
    (data[deflate_end + 1].to_uint() << 16) |
    (data[deflate_end + 2].to_uint() << 8) |
    data[deflate_end + 3].to_uint()
  let actual_checksum = @checksum.adler32(decompressed[:])
  if actual_checksum != expected_checksum {
    raise ZlibError::ChecksumMismatch(
      expected=expected_checksum,
      got=actual_checksum,
    )
  }
  decompressed
}
