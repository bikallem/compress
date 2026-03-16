///|
/// Decompresses Zstandard-encoded data.
pub fn decompress(data : Bytes) -> Bytes raise ZstdError {
  let src = data[:]
  let src_len = data.length()
  guard src_len >= 4 else { raise ZstdError::UnexpectedEOF }
  // Check magic number
  let magic = src[0].to_uint() |
    (src[1].to_uint() << 8) |
    (src[2].to_uint() << 16) |
    (src[3].to_uint() << 24)
  guard magic == ZSTD_MAGIC else {
    raise ZstdError::InvalidHeader("invalid magic number")
  }
  // Parse frame header descriptor
  guard src_len >= 5 else { raise ZstdError::UnexpectedEOF }
  let fhd = src[4].to_int()
  let fcs_flag = (fhd >> 6) & 0x03
  let single_segment = (fhd >> 5) & 0x01
  let has_checksum = (fhd >> 2) & 0x01
  let dict_id_flag = fhd & 0x03
  let mut pos = 5
  // Window descriptor (unless single segment)
  let mut window_size = 0
  if single_segment == 0 {
    guard pos < src_len else { raise ZstdError::UnexpectedEOF }
    let wd = src[pos].to_int()
    pos += 1
    let exponent = (wd >> 3) + 10
    let mantissa = wd & 0x07
    window_size = (1 << exponent) + (mantissa * (1 << (exponent - 3)))
    guard window_size <= MAX_WINDOW_SIZE else {
      raise ZstdError::WindowTooLarge("window size \{window_size} exceeds max")
    }
  }
  // Dictionary ID
  let dict_id_size = match dict_id_flag {
    0 => 0
    1 => 1
    2 => 2
    _ => 4
  }
  guard pos + dict_id_size <= src_len else { raise ZstdError::UnexpectedEOF }
  pos += dict_id_size
  // Frame content size
  let fcs_size = match fcs_flag {
    0 => if single_segment == 1 { 1 } else { 0 }
    1 => 2
    2 => 4
    _ => 8
  }
  guard pos + fcs_size <= src_len else { raise ZstdError::UnexpectedEOF }
  let content_size : Int? = if fcs_size == 0 {
    None
  } else if fcs_size == 1 {
    let v = src[pos].to_int()
    pos += 1
    Some(v)
  } else if fcs_size == 2 {
    let v = src[pos].to_int() | (src[pos + 1].to_int() << 8)
    pos += 2
    Some(v + 256)
  } else if fcs_size == 4 {
    let v = src[pos].to_int() |
      (src[pos + 1].to_int() << 8) |
      (src[pos + 2].to_int() << 16) |
      (src[pos + 3].to_int() << 24)
    pos += 4
    Some(v)
  } else {
    // 8 bytes — read lower 4 for now
    let v = src[pos].to_int() |
      (src[pos + 1].to_int() << 8) |
      (src[pos + 2].to_int() << 16) |
      (src[pos + 3].to_int() << 24)
    pos += 8
    Some(v)
  }
  // Set window size from content size for single segment
  if single_segment == 1 {
    match content_size {
      Some(cs) => window_size = cs
      None => ()
    }
  }
  // Decompress blocks
  let capacity = match content_size {
    Some(cs) => cs
    None => (src_len * 4).max(65536)
  }
  let sink = @output_sink.OutputSink::new(capacity)
  let xxh = @checksum.XXH64::new()
  while pos < src_len {
    guard pos + 3 <= src_len else { raise ZstdError::UnexpectedEOF }
    let bh = src[pos].to_int() | (src[pos + 1].to_int() << 8) | (src[pos + 2].to_int() << 16)
    pos += 3
    let last_block = bh & 1
    let block_type = (bh >> 1) & 3
    let block_size = bh >> 3
    if block_type == BLOCK_TYPE_RAW {
      guard pos + block_size <= src_len else { raise ZstdError::UnexpectedEOF }
      let block_data = Bytes::makei(block_size, fn(i) { src[pos + i] })
      sink.write_bytes(block_data)
      xxh.update(block_data[:])
      pos += block_size
    } else if block_type == BLOCK_TYPE_RLE {
      guard pos < src_len else { raise ZstdError::UnexpectedEOF }
      let rle_byte = src[pos]
      pos += 1
      let block_data = Bytes::make(block_size, rle_byte)
      sink.write_bytes(block_data)
      xxh.update(block_data[:])
    } else if block_type == BLOCK_TYPE_COMPRESSED {
      guard pos + block_size <= src_len else { raise ZstdError::UnexpectedEOF }
      let block_data = decompress_block(src, pos, block_size, window_size)
      sink.write_bytes(block_data)
      xxh.update(block_data[:])
      pos += block_size
    } else {
      raise ZstdError::CorruptData("reserved block type")
    }
    if last_block == 1 {
      break
    }
  }
  // Verify checksum
  if has_checksum == 1 {
    guard pos + 4 <= src_len else { raise ZstdError::UnexpectedEOF }
    let expected_cs = src[pos].to_uint() |
      (src[pos + 1].to_uint() << 8) |
      (src[pos + 2].to_uint() << 16) |
      (src[pos + 3].to_uint() << 24)
    let actual_cs = xxh.checksum64().to_uint()
    guard expected_cs == actual_cs else {
      raise ZstdError::ChecksumMismatch(expected=expected_cs, got=actual_cs)
    }
  }
  sink.to_bytes()
}

///|
/// Decompresses a single compressed block.
fn decompress_block(
  src : BytesView,
  block_start : Int,
  block_size : Int,
  _window_size : Int,
) -> Bytes raise ZstdError {
  let mut pos = block_start
  let block_end = block_start + block_size
  // Parse literals section
  guard pos < block_end else { raise ZstdError::CorruptData("empty compressed block") }
  let lit_header = src[pos].to_int()
  let lit_type = lit_header & 0x03
  let mut lit_data : Bytes = b""
  if lit_type == 0 {
    // Raw literals
    let size_format = (lit_header >> 2) & 0x03
    let (lit_size, header_bytes) = if size_format == 0 || size_format == 2 {
      // 1 byte header, size in bits 3-7
      ((lit_header >> 3) & 0x1F, 1)
    } else if size_format == 1 {
      // 2 byte header
      guard pos + 1 < block_end else { raise ZstdError::UnexpectedEOF }
      let h = lit_header | (src[pos + 1].to_int() << 8)
      ((h >> 4) & 0xFFF, 2)
    } else {
      // 3 byte header
      guard pos + 2 < block_end else { raise ZstdError::UnexpectedEOF }
      let h = lit_header | (src[pos + 1].to_int() << 8) | (src[pos + 2].to_int() << 16)
      ((h >> 4) & 0xFFFFF, 3)
    }
    pos += header_bytes
    guard pos + lit_size <= block_end else {
      raise ZstdError::CorruptData("literals extend past block")
    }
    lit_data = Bytes::makei(lit_size, fn(i) { src[pos + i] })
    pos += lit_size
  } else if lit_type == 1 {
    // RLE literals
    let size_format = (lit_header >> 2) & 0x03
    let (lit_size, header_bytes) = if size_format == 0 || size_format == 2 {
      ((lit_header >> 3) & 0x1F, 1)
    } else if size_format == 1 {
      guard pos + 1 < block_end else { raise ZstdError::UnexpectedEOF }
      let h = lit_header | (src[pos + 1].to_int() << 8)
      ((h >> 4) & 0xFFF, 2)
    } else {
      guard pos + 2 < block_end else { raise ZstdError::UnexpectedEOF }
      let h = lit_header | (src[pos + 1].to_int() << 8) | (src[pos + 2].to_int() << 16)
      ((h >> 4) & 0xFFFFF, 3)
    }
    pos += header_bytes
    guard pos < block_end else { raise ZstdError::UnexpectedEOF }
    let rle_byte = src[pos]
    pos += 1
    lit_data = Bytes::make(lit_size, rle_byte)
  } else {
    // Compressed or treeless literals — for now, fail gracefully
    raise ZstdError::CorruptData(
      "Huffman-compressed literals not yet supported in decompressor",
    )
  }
  // Parse sequences section
  if pos >= block_end {
    // No sequences, just literals
    return lit_data
  }
  let num_sequences = if src[pos].to_int() < 128 {
    let n = src[pos].to_int()
    pos += 1
    n
  } else if src[pos].to_int() < 255 {
    guard pos + 1 < block_end else { raise ZstdError::UnexpectedEOF }
    let n = ((src[pos].to_int() - 128) << 8) + src[pos + 1].to_int()
    pos += 2
    n
  } else {
    guard pos + 2 < block_end else { raise ZstdError::UnexpectedEOF }
    let n = src[pos + 1].to_int() + (src[pos + 2].to_int() << 8) + 0x7F00
    pos += 3
    n
  }
  if num_sequences == 0 {
    return lit_data
  }
  // Compression modes byte
  guard pos < block_end else { raise ZstdError::UnexpectedEOF }
  let _modes = src[pos].to_int()
  pos += 1
  // For now: decode using predefined tables and the bitstream
  // The remaining bytes [pos..block_end) contain the sequence bitstream (backward)
  let seq_data = Bytes::makei(block_end - pos, fn(i) { src[pos + i] })
  // Execute sequences
  let out = @buffer.new()
  let mut lit_pos = 0
  // Simple sequence decoding: read sequences from the backward bitstream
  let br = BackwardBitReader::new(seq_data[:])
  // Initialize FSE states (read initial states from bitstream)
  let ll_table = FseTable::build(ll_default_norm, 35, LL_DEFAULT_ACCURACY)
  let ml_table = FseTable::build(ml_default_norm, 52, ML_DEFAULT_ACCURACY)
  let of_table = FseTable::build(of_default_norm, 28, OF_DEFAULT_ACCURACY)
  let mut ll_state = br.read_bits(LL_DEFAULT_ACCURACY).reinterpret_as_int()
  let mut of_state = br.read_bits(OF_DEFAULT_ACCURACY).reinterpret_as_int()
  let mut ml_state = br.read_bits(ML_DEFAULT_ACCURACY).reinterpret_as_int()
  for i in 0..<num_sequences {
    // Decode offset
    let (of_sym, of_nb, of_base) = fse_decode_symbol(of_table, of_state)
    let of_code = of_sym.to_int()
    let offset = if of_code > 0 {
      (1 << of_code) + br.read_bits(of_code).reinterpret_as_int()
    } else {
      1
    }
    // Decode match length
    let (ml_sym, ml_nb, ml_base_state) = fse_decode_symbol(ml_table, ml_state)
    let ml_code = ml_sym.to_int()
    let match_len = if ml_code < 32 {
      ml_code + 3
    } else {
      let extra = ml_extra_bits[ml_code]
      ml_baselines[ml_code] + (if extra > 0 {
        br.read_bits(extra).reinterpret_as_int()
      } else {
        0
      })
    }
    // Decode literal length
    let (ll_sym, ll_nb, ll_base_state) = fse_decode_symbol(ll_table, ll_state)
    let ll_code = ll_sym.to_int()
    let lit_len = if ll_code < 16 {
      ll_code
    } else {
      let extra = ll_extra_bits[ll_code]
      ll_baselines[ll_code] + (if extra > 0 {
        br.read_bits(extra).reinterpret_as_int()
      } else {
        0
      })
    }
    // Update FSE states (not for last sequence)
    if i < num_sequences - 1 {
      ll_state = ll_base_state + br.read_bits(ll_nb).reinterpret_as_int()
      ml_state = ml_base_state + br.read_bits(ml_nb).reinterpret_as_int()
      of_state = of_base + br.read_bits(of_nb).reinterpret_as_int()
    }
    // Copy literals
    for j in 0..<lit_len {
      if lit_pos + j < lit_data.length() {
        out.write_byte(lit_data[lit_pos + j])
      }
    }
    lit_pos += lit_len
    // Copy match (from already-decoded output)
    let out_bytes = out.to_bytes()
    let out_len = out_bytes.length()
    for j in 0..<match_len {
      let src_idx = out_len - offset + (j % offset)
      if src_idx >= 0 && src_idx < out_bytes.length() {
        out.write_byte(out_bytes[src_idx])
      }
    }
  }
  // Copy remaining literals
  while lit_pos < lit_data.length() {
    out.write_byte(lit_data[lit_pos])
    lit_pos += 1
  }
  out.to_bytes()
}
