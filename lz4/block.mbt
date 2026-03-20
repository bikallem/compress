///|
/// Compresses a block using the LZ4 block format.
/// Returns the number of bytes written to dst, or 0 if incompressible.
fn block_compress(src : BytesView, dst : FixedArray[Byte]) -> Int {
  let src_len = src.length()
  if src_len < 13 {
    // Too small to compress
    return 0
  }
  // LZ4 requires the last 5 bytes (LASTLITERALS) to be emitted as literals.
  // mf_limit bounds both where matches can start and how far they extend.
  let mf_limit = src_len - 5
  let table = FixedArray::make(LZ4_HASH_SIZE, -1)
  let mut ip = 0 // input position
  let mut op = 0 // output position
  let mut anchor = 0 // start of pending literal
  let dst_limit = dst.length()
  while ip < mf_limit {
    let hash = lz4_hash(src, ip)
    let ref_pos = table.unsafe_get(hash)
    table.unsafe_set(hash, ip)
    // Check for match:
    // - ref_pos >= 0: valid table entry (not -1 init)
    // - ip - ref_pos < 65536: offset fits in 16 bits
    // - first 4 bytes match
    // Note: ref_pos < ip < mf_limit guarantees ref_pos+3 < src_len.
    if ref_pos >= 0 &&
      ip - ref_pos < 65536 &&
      src.unsafe_get(ref_pos) == src.unsafe_get(ip) &&
      src.unsafe_get(ref_pos + 1) == src.unsafe_get(ip + 1) &&
      src.unsafe_get(ref_pos + 2) == src.unsafe_get(ip + 2) &&
      src.unsafe_get(ref_pos + 3) == src.unsafe_get(ip + 3) {
      // Found match - emit literal + match sequence
      let lit_len = ip - anchor
      // Extend match forward (ref_pos < ip, so ref bound is implied by ip bound)
      let mut match_len = MIN_MATCH
      while ip + match_len < mf_limit &&
            src.unsafe_get(ref_pos + match_len) == src.unsafe_get(ip + match_len) {
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
        if op + 1 + remaining / 255 >= dst_limit {
          return 0
        }
        while remaining >= 255 {
          dst.unsafe_set(op, b'\xFF')
          op += 1
          remaining -= 255
        }
        dst.unsafe_set(op, remaining.to_byte())
        op += 1
      } else {
        token = lit_len << 4
      }
      // Copy literals
      if op + lit_len >= dst_limit {
        return 0
      }
      for i in 0..<lit_len {
        dst.unsafe_set(op + i, src.unsafe_get(anchor + i))
      }
      op += lit_len
      // Encode offset (little-endian 16-bit)
      let offset = ip - ref_pos
      if op + 2 >= dst_limit {
        return 0
      }
      dst.unsafe_set(op, (offset & 0xFF).to_byte())
      dst.unsafe_set(op + 1, ((offset >> 8) & 0xFF).to_byte())
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
          dst.unsafe_set(op, b'\xFF')
          op += 1
          remaining -= 255
        }
        if op >= dst_limit {
          return 0
        }
        dst.unsafe_set(op, remaining.to_byte())
        op += 1
      } else {
        token = token | ml
      }
      dst.unsafe_set(token_pos, token.to_byte())
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
    dst.unsafe_set(token_pos, (0xF0).to_byte())
    let mut remaining = last_lit_len - 15
    while remaining >= 255 {
      if op >= dst_limit {
        return 0
      }
      dst.unsafe_set(op, b'\xFF')
      op += 1
      remaining -= 255
    }
    if op >= dst_limit {
      return 0
    }
    dst.unsafe_set(op, remaining.to_byte())
    op += 1
  } else {
    dst.unsafe_set(token_pos, (last_lit_len << 4).to_byte())
  }
  if op + last_lit_len > dst_limit {
    return 0
  }
  for i in 0..<last_lit_len {
    dst.unsafe_set(op + i, src.unsafe_get(anchor + i))
  }
  op += last_lit_len
  op
}

///|
fn lz4_hash(data : BytesView, pos : Int) -> Int {
  let u = data.unsafe_get(pos).to_int() |
    (data.unsafe_get(pos + 1).to_int() << 8) |
    (data.unsafe_get(pos + 2).to_int() << 16) |
    (data.unsafe_get(pos + 3).to_int() << 24)
  ((u * 0x9E3779B1) >> 18) & LZ4_HASH_MASK
}
