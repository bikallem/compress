///|
/// Compresses a block using the LZ4 block format.
/// Returns the number of bytes written to dst, or 0 if incompressible.
fn block_compress(src : BytesView, dst : FixedArray[Byte]) -> Int {
  let src_len = src.length()
  if src_len < 13 {
    // Too small to compress
    return 0
  }
  let table = FixedArray::make(LZ4_HASH_SIZE, 0)
  let mut ip = 0 // input position
  let mut op = 0 // output position
  let mut anchor = 0 // start of pending literal
  let ip_limit = src_len - 5 // leave room for last literals
  let match_limit = src_len - MIN_MATCH
  let dst_limit = dst.length()
  while ip < ip_limit {
    let hash = lz4_hash(src, ip)
    let ref_pos = table[hash]
    table[hash] = ip
    // Check for match
    if ref_pos >= anchor &&
      ip - ref_pos < 65536 &&
      ip <= match_limit &&
      src[ref_pos] == src[ip] &&
      src[ref_pos + 1] == src[ip + 1] &&
      src[ref_pos + 2] == src[ip + 2] &&
      src[ref_pos + 3] == src[ip + 3] {
      // Found match - emit literal + match sequence
      let lit_len = ip - anchor
      // Extend match forward
      let mut match_len = MIN_MATCH
      while ip + match_len < src_len && src[ref_pos + match_len] == src[ip + match_len] {
        match_len += 1
      }
      // Encode sequence
      let token_pos = op
      op += 1
      if op >= dst_limit {
        return 0
      }
      // Encode literal length
      let mut token = 0
      if lit_len >= 15 {
        token = 0xF0
        let mut remaining = lit_len - 15
        if op + 1 + (remaining / 255) >= dst_limit {
          return 0
        }
        while remaining >= 255 {
          dst[op] = b'\xFF'
          op += 1
          remaining -= 255
        }
        dst[op] = remaining.to_byte()
        op += 1
      } else {
        token = lit_len << 4
      }
      // Copy literals
      if op + lit_len >= dst_limit {
        return 0
      }
      for i in 0..<lit_len {
        dst[op + i] = src[anchor + i]
      }
      op += lit_len
      // Encode offset (little-endian 16-bit)
      let offset = ip - ref_pos
      if op + 2 >= dst_limit {
        return 0
      }
      dst[op] = (offset & 0xFF).to_byte()
      dst[op + 1] = ((offset >> 8) & 0xFF).to_byte()
      op += 2
      // Encode match length
      let ml = match_len - MIN_MATCH
      if ml >= 15 {
        token = token | 0x0F
        let mut remaining = ml - 15
        while remaining >= 255 {
          if op >= dst_limit {
            return 0
          }
          dst[op] = b'\xFF'
          op += 1
          remaining -= 255
        }
        if op >= dst_limit {
          return 0
        }
        dst[op] = remaining.to_byte()
        op += 1
      } else {
        token = token | ml
      }
      dst[token_pos] = token.to_byte()
      ip += match_len
      anchor = ip
      continue
    }
    ip += 1
  }
  // Emit last literals
  let last_lit_len = src_len - anchor
  let token_pos = op
  op += 1
  if op >= dst_limit {
    return 0
  }
  if last_lit_len >= 15 {
    dst[token_pos] = 0xF0.to_byte()
    let mut remaining = last_lit_len - 15
    while remaining >= 255 {
      if op >= dst_limit {
        return 0
      }
      dst[op] = b'\xFF'
      op += 1
      remaining -= 255
    }
    if op >= dst_limit {
      return 0
    }
    dst[op] = remaining.to_byte()
    op += 1
  } else {
    dst[token_pos] = (last_lit_len << 4).to_byte()
  }
  if op + last_lit_len > dst_limit {
    return 0
  }
  for i in 0..<last_lit_len {
    dst[op + i] = src[anchor + i]
  }
  op += last_lit_len
  op
}

///|
fn lz4_hash(data : BytesView, pos : Int) -> Int {
  let u = data[pos].to_int() |
    (data[pos + 1].to_int() << 8) |
    (data[pos + 2].to_int() << 16) |
    (data[pos + 3].to_int() << 24)
  ((u * 0x9E3779B1) >> 18) & LZ4_HASH_MASK
}
