///|
/// Compresses a block using the LZ4 block format.
/// Returns the number of bytes written to dst, or 0 if incompressible.
fn block_compress(src : BytesView, dst : FixedArray[Byte]) -> Int {
  block_compress_window(src, 0, src.length(), dst)
}

///|
/// Compresses a block using up to 64KiB of prior output as a dependent-block
/// prefix. Returns the number of bytes written to `dst`, or 0 if the block is
/// incompressible.
fn block_compress_with_history(
  history : BytesView,
  src : BytesView,
  dst : FixedArray[Byte],
) -> Int {
  if history.length() == 0 {
    return block_compress(src, dst)
  }
  let combined = @blit.Buffer::new(size_hint=history.length() + src.length())
  combined.write_bytesview(history)
  combined.write_bytesview(src)
  let combined_bytes = combined.to_bytes()
  block_compress_window(
    combined_bytes[:],
    history.length(),
    combined_bytes.length(),
    dst,
  )
}

///|
fn block_compress_window(
  src : BytesView,
  block_start : Int,
  block_end : Int,
  dst : FixedArray[Byte],
) -> Int {
  let src_len = block_end - block_start
  if src_len < 13 {
    return 0
  }
  // LZ4 requires the last 5 bytes (LASTLITERALS) to be emitted as literals.
  // mf_limit bounds both where matches can start and how far they extend.
  let mf_limit = block_end - 5
  let table = FixedArray::make(LZ4_HASH_SIZE, -1)
  let prefix_start = (block_start - 65535).max(0)
  let hash_limit = block_end - 3
  let mut seed_pos = prefix_start
  while seed_pos < block_start && seed_pos < hash_limit {
    table.unsafe_set(lz4_hash(src, seed_pos), seed_pos)
    seed_pos += 1
  }
  let mut ip = block_start // input position
  let mut op = 0 // output position
  let mut anchor = block_start // start of pending literal
  let dst_limit = dst.length()
  while ip < mf_limit {
    let hash = lz4_hash(src, ip)
    let ref_pos = table.unsafe_get(hash)
    table.unsafe_set(hash, ip)
    if ref_pos >= 0 &&
      ip - ref_pos < 65536 &&
      src.unsafe_get(ref_pos) == src.unsafe_get(ip) &&
      src.unsafe_get(ref_pos + 1) == src.unsafe_get(ip + 1) &&
      src.unsafe_get(ref_pos + 2) == src.unsafe_get(ip + 2) &&
      src.unsafe_get(ref_pos + 3) == src.unsafe_get(ip + 3) {
      let lit_len = ip - anchor
      let mut match_len = MIN_MATCH
      while ip + match_len < mf_limit &&
            src.unsafe_get(ref_pos + match_len) ==
            src.unsafe_get(ip + match_len) {
        match_len += 1
      }
      let token_pos = op
      op += 1
      if op >= dst_limit {
        return 0
      }
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
      if op + lit_len >= dst_limit {
        return 0
      }
      for i in 0..<lit_len {
        dst.unsafe_set(op + i, src.unsafe_get(anchor + i))
      }
      op += lit_len
      let offset = ip - ref_pos
      if op + 2 >= dst_limit {
        return 0
      }
      dst.unsafe_set(op, (offset & 0xFF).to_byte())
      dst.unsafe_set(op + 1, ((offset >> 8) & 0xFF).to_byte())
      op += 2
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
  let last_lit_len = block_end - anchor
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
