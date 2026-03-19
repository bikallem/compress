///|
/// Decompresses an LZ4 block into dst. Returns bytes written.
fn block_decompress(
  src : BytesView,
  src_pos_ : Int,
  src_end : Int,
  dst : FixedArray[Byte],
  dst_pos_ : Int,
  dst_capacity : Int,
) -> (Int, Int) raise Lz4Error {
  let mut src_pos = src_pos_
  let mut dst_pos = dst_pos_
  while src_pos < src_end {
    let token = src[src_pos].to_int()
    src_pos += 1
    // Decode literal length
    let mut lit_len = (token >> 4) & 0x0F
    if lit_len == 15 {
      while src_pos < src_end {
        let b = src[src_pos].to_int()
        src_pos += 1
        lit_len += b
        if b != 255 {
          break
        }
      }
    }
    // Copy literals
    guard src_pos + lit_len <= src_end else { raise Lz4Error::UnexpectedEOF }
    guard dst_pos + lit_len <= dst_capacity else {
      raise Lz4Error::CorruptData("literal overflow")
    }
    for i in 0..<lit_len {
      dst[dst_pos + i] = src[src_pos + i]
    }
    src_pos += lit_len
    dst_pos += lit_len
    // Check for end of block (last sequence has no match)
    if src_pos >= src_end {
      break
    }
    // Decode offset (little-endian 16-bit)
    guard src_pos + 2 <= src_end else { raise Lz4Error::UnexpectedEOF }
    let offset = src[src_pos].to_int() | (src[src_pos + 1].to_int() << 8)
    src_pos += 2
    guard offset > 0 else { raise Lz4Error::CorruptData("zero match offset") }
    guard offset <= dst_pos else {
      raise Lz4Error::CorruptData("match offset beyond output")
    }
    // Decode match length
    let mut match_len = (token & 0x0F) + MIN_MATCH
    if (token & 0x0F) == 15 {
      while src_pos < src_end {
        let b = src[src_pos].to_int()
        src_pos += 1
        match_len += b
        if b != 255 {
          break
        }
      }
    }
    guard dst_pos + match_len <= dst_capacity else {
      raise Lz4Error::CorruptData("match overflow")
    }
    // Copy match (with possible overlap)
    let match_start = dst_pos - offset
    for i in 0..<match_len {
      dst[dst_pos + i] = dst[match_start + i % offset]
    }
    dst_pos += match_len
  }
  (dst_pos, src_pos)
}
