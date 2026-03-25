///|
/// Decompresses Zstandard-encoded data.
pub fn decompress(data : Bytes) -> Bytes raise ZstdError {
  let src = data[:]
  let src_len = data.length()
  guard src_len >= 4 else { raise ZstdError::UnexpectedEOF }
  // Check magic number
  let magic = src.unsafe_get(0).to_uint() |
    (src.unsafe_get(1).to_uint() << 8) |
    (src.unsafe_get(2).to_uint() << 16) |
    (src.unsafe_get(3).to_uint() << 24)
  guard magic == ZSTD_MAGIC else {
    raise ZstdError::InvalidHeader("invalid magic number")
  }
  // Parse frame header descriptor
  guard src_len >= 5 else { raise ZstdError::UnexpectedEOF }
  let fhd = src.unsafe_get(4).to_int()
  let fcs_flag = (fhd >> 6) & 0x03
  let single_segment = (fhd >> 5) & 0x01
  let has_checksum = (fhd >> 2) & 0x01
  let dict_id_flag = fhd & 0x03
  let mut pos = 5
  // Window descriptor (unless single segment)
  let mut window_size = 0
  if single_segment == 0 {
    guard pos < src_len else { raise ZstdError::UnexpectedEOF }
    let wd = src.unsafe_get(pos).to_int()
    pos += 1
    let exponent = (wd >> 3) + 10
    let mantissa = wd & 0x07
    window_size = (1 << exponent) + mantissa * (1 << (exponent - 3))
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
  let content_size : Int? = match fcs_size {
    0 => None
    1 => {
      let v = src.unsafe_get(pos).to_int()
      pos += 1
      Some(v)
    }
    2 => {
      let v = src.unsafe_get(pos).to_int() |
        (src.unsafe_get(pos + 1).to_int() << 8)
      pos += 2
      Some(v + 256)
    }
    4 => {
      let v = src.unsafe_get(pos).to_int() |
        (src.unsafe_get(pos + 1).to_int() << 8) |
        (src.unsafe_get(pos + 2).to_int() << 16) |
        (src.unsafe_get(pos + 3).to_int() << 24)
      pos += 4
      Some(v)
    }
    _ => {
      // 8 bytes — read lower 4 for now
      let v = src.unsafe_get(pos).to_int() |
        (src.unsafe_get(pos + 1).to_int() << 8) |
        (src.unsafe_get(pos + 2).to_int() << 16) |
        (src.unsafe_get(pos + 3).to_int() << 24)
      pos += 8
      Some(v)
    }
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
  let sink = @blit.Buffer::new(size_hint=capacity)
  let xxh = @checksum.XXH64::new()
  // Repeat offsets persist across blocks within a frame
  let rep = [1, 4, 8]
  let mut saw_last_block = false
  while !saw_last_block {
    guard pos + 3 <= src_len else { raise ZstdError::UnexpectedEOF }
    let bh = src.unsafe_get(pos).to_int() |
      (src.unsafe_get(pos + 1).to_int() << 8) |
      (src.unsafe_get(pos + 2).to_int() << 16)
    pos += 3
    let last_block = bh & 1
    let block_type = (bh >> 1) & 3
    let block_size = bh >> 3
    if block_type == BLOCK_TYPE_RAW {
      guard pos + block_size <= src_len else { raise ZstdError::UnexpectedEOF }
      let block_data = Bytes::makei(block_size, fn(i) {
        src.unsafe_get(pos + i)
      })
      sink.write_bytes(block_data)
      xxh.update(block_data[:])
      pos += block_size
    } else if block_type == BLOCK_TYPE_RLE {
      guard pos < src_len else { raise ZstdError::UnexpectedEOF }
      let rle_byte = src.unsafe_get(pos)
      pos += 1
      let block_data = Bytes::make(block_size, rle_byte)
      sink.write_bytes(block_data)
      xxh.update(block_data[:])
    } else if block_type == BLOCK_TYPE_COMPRESSED {
      guard pos + block_size <= src_len else { raise ZstdError::UnexpectedEOF }
      let block_data = decompress_block(
        src, pos, block_size, window_size, sink, rep,
      )
      sink.write_bytes(block_data)
      xxh.update(block_data[:])
      pos += block_size
    } else {
      raise ZstdError::CorruptData("reserved block type")
    }
    saw_last_block = last_block == 1
  }
  // Verify checksum
  if has_checksum == 1 {
    guard pos + 4 <= src_len else { raise ZstdError::UnexpectedEOF }
    let expected_cs = src.unsafe_get(pos).to_uint() |
      (src.unsafe_get(pos + 1).to_uint() << 8) |
      (src.unsafe_get(pos + 2).to_uint() << 16) |
      (src.unsafe_get(pos + 3).to_uint() << 24)
    let actual_cs = xxh.checksum64().to_uint()
    guard expected_cs == actual_cs else {
      raise ZstdError::ChecksumMismatch(expected=expected_cs, got=actual_cs)
    }
  }
  sink.to_bytes()
}

///|
/// Decompresses a single compressed block.
/// `prev_output` is the accumulated output from previous blocks (for cross-block back-references).
/// `rep` is the repeat offset state, modified in place.
fn decompress_block(
  src : BytesView,
  block_start : Int,
  block_size : Int,
  _window_size : Int,
  prev_output : @blit.Buffer,
  rep : Array[Int],
) -> Bytes raise ZstdError {
  let mut pos = block_start
  let block_end = block_start + block_size
  // Parse literals section
  guard pos < block_end else {
    raise ZstdError::CorruptData("empty compressed block")
  }
  let lit_header = src.unsafe_get(pos).to_int()
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
      let h = lit_header | (src.unsafe_get(pos + 1).to_int() << 8)
      ((h >> 4) & 0xFFF, 2)
    } else {
      // 3 byte header
      guard pos + 2 < block_end else { raise ZstdError::UnexpectedEOF }
      let h = lit_header |
        (src.unsafe_get(pos + 1).to_int() << 8) |
        (src.unsafe_get(pos + 2).to_int() << 16)
      ((h >> 4) & 0xFFFFF, 3)
    }
    pos += header_bytes
    guard pos + lit_size <= block_end else {
      raise ZstdError::CorruptData("literals extend past block")
    }
    lit_data = Bytes::makei(lit_size, fn(i) { src.unsafe_get(pos + i) })
    pos += lit_size
  } else if lit_type == 1 {
    // RLE literals
    let size_format = (lit_header >> 2) & 0x03
    let (lit_size, header_bytes) = if size_format == 0 || size_format == 2 {
      ((lit_header >> 3) & 0x1F, 1)
    } else if size_format == 1 {
      guard pos + 1 < block_end else { raise ZstdError::UnexpectedEOF }
      let h = lit_header | (src.unsafe_get(pos + 1).to_int() << 8)
      ((h >> 4) & 0xFFF, 2)
    } else {
      guard pos + 2 < block_end else { raise ZstdError::UnexpectedEOF }
      let h = lit_header |
        (src.unsafe_get(pos + 1).to_int() << 8) |
        (src.unsafe_get(pos + 2).to_int() << 16)
      ((h >> 4) & 0xFFFFF, 3)
    }
    pos += header_bytes
    guard pos < block_end else { raise ZstdError::UnexpectedEOF }
    let rle_byte = src.unsafe_get(pos)
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
  let num_sequences = if src.unsafe_get(pos).to_int() < 128 {
    let n = src.unsafe_get(pos).to_int()
    pos += 1
    n
  } else if src.unsafe_get(pos).to_int() < 255 {
    guard pos + 1 < block_end else { raise ZstdError::UnexpectedEOF }
    let n = ((src.unsafe_get(pos).to_int() - 128) << 8) +
      src.unsafe_get(pos + 1).to_int()
    pos += 2
    n
  } else {
    guard pos + 2 < block_end else { raise ZstdError::UnexpectedEOF }
    let n = src.unsafe_get(pos + 1).to_int() +
      (src.unsafe_get(pos + 2).to_int() << 8) +
      0x7F00
    pos += 3
    n
  }
  if num_sequences == 0 {
    return lit_data
  }
  // Compression modes byte
  guard pos < block_end else { raise ZstdError::UnexpectedEOF }
  let modes = src.unsafe_get(pos).to_int()
  pos += 1
  guard modes == 0 else {
    raise ZstdError::CorruptData(
      "sequence compression modes other than predefined are not supported",
    )
  }
  // For now: decode using predefined tables and the bitstream
  // The remaining bytes [pos..block_end) contain the sequence bitstream (backward)
  let seq_data = Bytes::makei(block_end - pos, fn(i) { src.unsafe_get(pos + i) })
  // Execute sequences using a local output sink for this block
  let block_out = @blit.Buffer::new(
    size_hint=if num_sequences > 0 { 65536 } else { lit_data.length() },
  )
  let mut lit_pos = 0
  let prev_len = prev_output.length()
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
    // Decode offset_value from FSE + extra bits
    let (of_sym, of_nb, of_base) = fse_decode_symbol(of_table, of_state)
    let of_code = of_sym.to_int()
    let offset_value = if of_code > 0 {
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
      let extra = ml_extra_bits.unsafe_get(ml_code)
      ml_baselines.unsafe_get(ml_code) +
      (if extra > 0 { br.read_bits(extra).reinterpret_as_int() } else { 0 })
    }
    // Decode literal length
    let (ll_sym, ll_nb, ll_base_state) = fse_decode_symbol(ll_table, ll_state)
    let ll_code = ll_sym.to_int()
    let lit_len = if ll_code < 16 {
      ll_code
    } else {
      let extra = ll_extra_bits.unsafe_get(ll_code)
      ll_baselines.unsafe_get(ll_code) +
      (if extra > 0 { br.read_bits(extra).reinterpret_as_int() } else { 0 })
    }
    // Update FSE states (not for last sequence)
    if i < num_sequences - 1 {
      ll_state = ll_base_state + br.read_bits(ll_nb).reinterpret_as_int()
      ml_state = ml_base_state + br.read_bits(ml_nb).reinterpret_as_int()
      of_state = of_base + br.read_bits(of_nb).reinterpret_as_int()
    }
    // Resolve repeat offsets per RFC 8878 section 3.1.1.5
    let offset = if offset_value > 3 {
      // New offset
      let actual = offset_value - 3
      rep.unsafe_set(2, rep.unsafe_get(1))
      rep.unsafe_set(1, rep.unsafe_get(0))
      rep.unsafe_set(0, actual)
      actual
    } else if offset_value == 1 {
      if lit_len == 0 {
        let tmp = rep.unsafe_get(0)
        rep.unsafe_set(0, rep.unsafe_get(1))
        rep.unsafe_set(1, tmp)
        rep.unsafe_get(0)
      } else {
        rep.unsafe_get(0)
      }
    } else if offset_value == 2 {
      if lit_len == 0 {
        let tmp = rep.unsafe_get(2)
        rep.unsafe_set(2, rep.unsafe_get(1))
        rep.unsafe_set(1, rep.unsafe_get(0))
        rep.unsafe_set(0, tmp)
        rep.unsafe_get(0)
      } else {
        let tmp = rep.unsafe_get(1)
        rep.unsafe_set(1, rep.unsafe_get(0))
        rep.unsafe_set(0, tmp)
        rep.unsafe_get(0)
      }
      // offset_value == 3
    } else if lit_len == 0 {
      let actual = rep.unsafe_get(0) - 1
      rep.unsafe_set(2, rep.unsafe_get(1))
      rep.unsafe_set(1, rep.unsafe_get(0))
      rep.unsafe_set(0, actual)
      actual
    } else {
      let tmp = rep.unsafe_get(2)
      rep.unsafe_set(2, rep.unsafe_get(1))
      rep.unsafe_set(1, rep.unsafe_get(0))
      rep.unsafe_set(0, tmp)
      rep.unsafe_get(0)
    }
    // Copy literals
    for j in 0..<lit_len {
      if lit_pos + j < lit_data.length() {
        block_out.write_byte(lit_data.unsafe_get(lit_pos + j))
      }
    }
    lit_pos += lit_len
    // Copy match (from accumulated output including previous blocks)
    let total_len = prev_len + block_out.length()
    for j in 0..<match_len {
      let src_idx = total_len - offset + j % offset
      if src_idx >= 0 {
        let byte = if src_idx < prev_len {
          prev_output.get_byte(src_idx)
        } else {
          block_out.get_byte(src_idx - prev_len)
        }
        block_out.write_byte(byte)
      }
    }
  }
  // Copy remaining literals
  while lit_pos < lit_data.length() {
    block_out.write_byte(lit_data.unsafe_get(lit_pos))
    lit_pos += 1
  }
  block_out.to_bytes()
}
