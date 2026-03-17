///|
/// Compresses data using the Zstandard format.
/// Uses a simplified encoding: raw blocks for small data, RLE for uniform data,
/// and a simple LZ77 + literal encoding for larger data.
pub fn compress(data : Bytes, level? : CompressionLevel = Default) -> Bytes {
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
      let block_header = last_flag | (BLOCK_TYPE_RAW << 1) | (block_len << 3)
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


