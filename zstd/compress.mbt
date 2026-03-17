///|
/// Compresses data using the Zstandard format.
/// Uses a simplified encoding: raw blocks for small data, RLE for uniform data,
/// and a simple LZ77 + literal encoding for larger data.
pub fn compress(
  data : Bytes,
  level? : CompressionLevel = Default,
) -> Bytes {
  ignore(level)
  let src = data[:]
  let src_len = data.length()
  // Allocate output buffer: frame header + blocks + checksum
  let max_out = 14 + src_len + (src_len / MAX_BLOCK_SIZE + 1) * 6 + 4
  let out = FixedArray::make(max_out, b'\x00')
  let mut pos = 0
  // Write frame header
  pos += write_zstd_frame_header(out, pos, src_len)
  // Content hasher for frame checksum
  let xxh = @checksum.XXH64::new()
  xxh.update(src)
  if src_len == 0 {
    // Empty data: single empty raw block (last_block=1, type=raw, size=0)
    let block_header = 1 // last_block=1, type=0 (raw), size=0
    out[pos] = (block_header & 0xFF).to_byte()
    out[pos + 1] = ((block_header >> 8) & 0xFF).to_byte()
    out[pos + 2] = ((block_header >> 16) & 0xFF).to_byte()
    pos += 3
  } else if is_all_same(src) {
    // RLE block: single byte repeated
    let block_header = 1 | (BLOCK_TYPE_RLE << 1) | (src_len << 3)
    out[pos] = (block_header & 0xFF).to_byte()
    out[pos + 1] = ((block_header >> 8) & 0xFF).to_byte()
    out[pos + 2] = ((block_header >> 16) & 0xFF).to_byte()
    pos += 3
    out[pos] = src[0]
    pos += 1
  } else {
    // Compress in blocks
    let mut src_pos = 0
    while src_pos < src_len {
      let block_end = if src_pos + MAX_BLOCK_SIZE < src_len {
        src_pos + MAX_BLOCK_SIZE
      } else {
        src_len
      }
      let block_len = block_end - src_pos
      let is_last = block_end == src_len
      let last_flag = if is_last { 1 } else { 0 }
      // Use raw blocks for correctness (compressed block encoding is WIP)
      let block_header = last_flag |
        (BLOCK_TYPE_RAW << 1) |
        (block_len << 3)
      out[pos] = (block_header & 0xFF).to_byte()
      out[pos + 1] = ((block_header >> 8) & 0xFF).to_byte()
      out[pos + 2] = ((block_header >> 16) & 0xFF).to_byte()
      pos += 3
      for i in 0..<block_len {
        out[pos + i] = src[src_pos + i]
      }
      pos += block_len
      src_pos = block_end
    }
  }
  // Write frame checksum (lower 32 bits of XXH64)
  let cs = xxh.checksum64()
  let cs32 = cs.to_uint()
  out[pos] = (cs32 & 0xFFU).to_byte()
  out[pos + 1] = ((cs32 >> 8) & 0xFFU).to_byte()
  out[pos + 2] = ((cs32 >> 16) & 0xFFU).to_byte()
  out[pos + 3] = ((cs32 >> 24) & 0xFFU).to_byte()
  pos += 4
  let result = @blit.make_uninit(pos)
  @blit.blit_fixed_array(result, 0, out, 0, pos)
  result.unsafe_reinterpret_as_bytes()
}

///|
fn is_all_same(data : BytesView) -> Bool {
  if data.length() <= 1 {
    return true
  }
  let first = data[0]
  for i in 1..<data.length() {
    if data[i] != first {
      return false
    }
  }
  true
}

///|
/// Writes a zstd frame header. Returns bytes written.
fn write_zstd_frame_header(
  dst : FixedArray[Byte],
  pos_ : Int,
  content_size : Int,
) -> Int {
  let mut pos = pos_
  let start = pos
  // Magic number (little-endian)
  dst[pos] = (ZSTD_MAGIC & 0xFFU).to_byte()
  dst[pos + 1] = ((ZSTD_MAGIC >> 8) & 0xFFU).to_byte()
  dst[pos + 2] = ((ZSTD_MAGIC >> 16) & 0xFFU).to_byte()
  dst[pos + 3] = ((ZSTD_MAGIC >> 24) & 0xFFU).to_byte()
  pos += 4
  // Frame Header Descriptor (FHD byte)
  // Bit 0: dictionary ID flag = 0 (no dict)
  // Bit 1: content checksum flag = 1
  // Bit 2: reserved = 0
  // Bit 3: unused = 0
  // Bit 4: single segment = depends on size
  // Bits 5-6: unused = 0
  // Bits 7-6: frame content size flag
  let (fcs_field, fcs_bytes) = if content_size == 0 {
    (0, 0) // when single_segment=1 and size=0, fcs_field=0 means 1 byte
  } else if content_size <= 255 {
    (0, 1) // 1 byte
  } else if content_size <= 65535 + 256 {
    (1, 2) // 2 bytes
  } else {
    (2, 4) // 4 bytes
  }
  let single_segment = 1 // always single segment (no window descriptor)
  let fhd = (fcs_field << 6) | (single_segment << 5) | 0x04 // content checksum flag
  dst[pos] = fhd.to_byte()
  pos += 1
  // Frame content size
  if fcs_bytes == 0 {
    // For single_segment with fcs_field=0, FCS is 1 byte
    dst[pos] = content_size.to_byte()
    pos += 1
  } else if fcs_bytes == 1 {
    dst[pos] = content_size.to_byte()
    pos += 1
  } else if fcs_bytes == 2 {
    let val = content_size - 256
    dst[pos] = (val & 0xFF).to_byte()
    dst[pos + 1] = ((val >> 8) & 0xFF).to_byte()
    pos += 2
  } else {
    dst[pos] = (content_size & 0xFF).to_byte()
    dst[pos + 1] = ((content_size >> 8) & 0xFF).to_byte()
    dst[pos + 2] = ((content_size >> 16) & 0xFF).to_byte()
    dst[pos + 3] = ((content_size >> 24) & 0xFF).to_byte()
    pos += 4
  }
  pos - start
}

///|
/// Simple block compression using raw literals + sequences.
/// Returns compressed block content, or empty if incompressible.
fn compress_block_simple(
  src : BytesView,
  block_start : Int,
  block_end : Int,
) -> Bytes {
  let block_len = block_end - block_start
  if block_len < 32 {
    // Too small to benefit from compression
    return Bytes::default()
  }
  // Find matches using hash table
  let table = FixedArray::make(ZSTD_HASH_SIZE, -1)
  let literals = @buffer.new()
  let sequences : Array[(Int, Int, Int)] = [] // (lit_len, match_len, offset)
  let mut ip = block_start
  let mut anchor = block_start
  let ip_limit = block_end - 8
  while ip < ip_limit {
    let hash = zstd_hash(src, ip)
    let ref_pos = table[hash]
    table[hash] = ip
    if ref_pos >= block_start &&
      ip - ref_pos < 65536 &&
      src[ref_pos] == src[ip] &&
      src[ref_pos + 1] == src[ip + 1] &&
      src[ref_pos + 2] == src[ip + 2] {
      let lit_len = ip - anchor
      // Add literals
      for j in anchor..<ip {
        literals.write_byte(src[j])
      }
      // Extend match
      let mut match_len = 3
      while ip + match_len < block_end && src[ref_pos + match_len] == src[ip + match_len] {
        match_len += 1
      }
      let offset = ip - ref_pos
      sequences.push((lit_len, match_len, offset))
      ip += match_len
      anchor = ip
      continue
    }
    ip += 1
  }
  // Add trailing literals
  let trailing_lits = block_end - anchor
  for j in anchor..<block_end {
    literals.write_byte(src[j])
  }
  if sequences.length() == 0 {
    return Bytes::default()
  }
  // Encode the block: literals section + sequences section
  let out = @buffer.new()
  let lit_data = literals.to_bytes()
  // Literals section header (raw literals)
  // Type 0 (raw), size encoding depends on size
  if lit_data.length() < 32 {
    // 1-byte header: type=0, size in bits 3-7
    out.write_byte(((lit_data.length() << 3) & 0xF8).to_byte())
  } else if lit_data.length() < 4096 {
    // 2-byte header
    let h = 0x01 | (lit_data.length() << 4) // size_format=01
    out.write_byte((h & 0xFF).to_byte())
    out.write_byte(((h >> 8) & 0xFF).to_byte())
  } else {
    // 3-byte header
    let h = 0x02 | (lit_data.length() << 4) // size_format=10
    out.write_byte((h & 0xFF).to_byte())
    out.write_byte(((h >> 8) & 0xFF).to_byte())
    out.write_byte(((h >> 16) & 0xFF).to_byte())
  }
  out.write_bytes(lit_data)
  // Sequences section header
  let num_seq = sequences.length()
  if num_seq < 128 {
    out.write_byte(num_seq.to_byte())
  } else if num_seq < 0x7F00 + 128 {
    let val = num_seq - 128
    out.write_byte(((val >> 8) + 128).to_byte())
    out.write_byte((val & 0xFF).to_byte())
  } else {
    out.write_byte(b'\xFF')
    let val = num_seq - 0x7F00 - 128
    out.write_byte((val & 0xFF).to_byte())
    out.write_byte(((val >> 8) & 0xFF).to_byte())
  }
  // Symbol compression modes: all predefined (0)
  out.write_byte(b'\x00') // compression mode byte: all predefined
  // Encode sequences as a bitstream (forward, then reversed for output)
  // For simplicity, use a forward-written bitstream
  let seq_bits = @buffer.new()
  let mut bit_buf : UInt64 = 0UL
  let mut n_bits = 0
  fn flush_bits() -> Unit {
    while n_bits >= 8 {
      seq_bits.write_byte((bit_buf & 0xFFUL).to_uint().to_byte())
      bit_buf = bit_buf >> 8
      n_bits -= 8
    }
  }

  fn write_bits(val : UInt, bits : Int) -> Unit {
    bit_buf = bit_buf | (val.to_uint64() << n_bits)
    n_bits += bits
    flush_bits()
  }

  // Encode each sequence
  for i in 0..<sequences.length() {
    let (lit_len, match_len, offset) = sequences[i]
    // Encode offset code
    let of_code = highest_bit(offset) - 1
    write_bits(
      (offset - (1 << of_code)).reinterpret_as_uint(),
      if of_code > 0 { of_code } else { 0 },
    )
    // Encode match length code
    let ml_value = match_len - ZSTD_MIN_MATCH
    let (ml_code, ml_extra, ml_extra_bits_count) = encode_ml(ml_value)
    if ml_extra_bits_count > 0 {
      write_bits(ml_extra.reinterpret_as_uint(), ml_extra_bits_count)
    }
    // Encode literal length code
    let (ll_code, ll_extra, ll_extra_bits_count) = encode_ll(lit_len)
    if ll_extra_bits_count > 0 {
      write_bits(ll_extra.reinterpret_as_uint(), ll_extra_bits_count)
    }
    ignore(of_code)
    ignore(ml_code)
    ignore(ll_code)
  }
  // Flush remaining bits with sentinel
  bit_buf = bit_buf | (1UL << n_bits) // sentinel bit
  n_bits += 1
  while n_bits > 0 {
    seq_bits.write_byte((bit_buf & 0xFFUL).to_uint().to_byte())
    bit_buf = bit_buf >> 8
    n_bits -= 8
  }
  // Reverse the bitstream (zstd uses backward bitstream for sequences)
  let seq_data = seq_bits.to_bytes()
  let reversed = Bytes::makei(seq_data.length(), fn(i) {
    seq_data[seq_data.length() - 1 - i]
  })
  out.write_bytes(reversed)
  ignore(trailing_lits)
  let result = out.to_bytes()
  // Only return if it's actually smaller
  if result.length() < block_len {
    result
  } else {
    Bytes::default()
  }
}

///|
fn zstd_hash(data : BytesView, pos : Int) -> Int {
  let u = data[pos].to_int() |
    (data[pos + 1].to_int() << 8) |
    (data[pos + 2].to_int() << 16) |
    (data[pos + 3].to_int() << 24)
  ((u * 0x9E3779B1) >> 18) & ZSTD_HASH_MASK
}

///|
fn encode_ll(lit_len : Int) -> (Int, Int, Int) {
  if lit_len < 16 {
    (lit_len, 0, 0)
  } else {
    for i = 16; i < 36; i = i + 1 {
      if i == 35 || lit_len < ll_baselines[i + 1] {
        let extra = lit_len - ll_baselines[i]
        return (i, extra, ll_extra_bits[i])
      }
    } else {
      (35, lit_len - ll_baselines[35], ll_extra_bits[35])
    }
  }
}

///|
fn encode_ml(ml_value : Int) -> (Int, Int, Int) {
  if ml_value < 32 {
    (ml_value, 0, 0)
  } else {
    for i = 32; i < 53; i = i + 1 {
      let baseline = ml_baselines[i] - 3
      let next_baseline = if i < 52 { ml_baselines[i + 1] - 3 } else { 0x7FFFFFFF }
      if ml_value < next_baseline {
        let extra = ml_value - baseline
        return (i, extra, ml_extra_bits[i])
      }
    } else {
      (52, ml_value - (ml_baselines[52] - 3), ml_extra_bits[52])
    }
  }
}
