///|
/// Compresses data using the Snappy algorithm.
pub fn compress(data : Bytes) -> Bytes {
  let enc = Encoder::new()
  enc.write(data[:])
  enc.close()
}

///|
/// Internal Snappy compression state.
priv struct Encoder {
  mut out_buf : FixedArray[Byte]
  mut out_pos : Int
  table : FixedArray[Int] // hash table: hash -> position in input
}

///|
fn Encoder::new() -> Encoder {
  {
    out_buf: FixedArray::make(4096, b'\x00'),
    out_pos: 0,
    table: FixedArray::make(HASH_TABLE_SIZE, 0),
  }
}

///|
fn Encoder::ensure_capacity(self : Encoder, additional : Int) -> Unit {
  while self.out_pos + additional >= self.out_buf.length() {
    let old = self.out_buf
    let new_len = old.length() * 2
    let new_buf = FixedArray::make(new_len, b'\x00')
    FixedArray::unsafe_blit(new_buf, 0, old, 0, self.out_pos)
    self.out_buf = new_buf
  }
}

///|
/// Encodes the uncompressed length as a varint at the start.
fn Encoder::emit_varint(self : Encoder, n_ : Int) -> Unit {
  let mut n = n_
  self.ensure_capacity(5)
  while n >= 128 {
    self.out_buf.unsafe_set(self.out_pos, ((n & 0x7F) | 0x80).to_byte())
    self.out_pos += 1
    n = n >> 7
  }
  self.out_buf.unsafe_set(self.out_pos, n.to_byte())
  self.out_pos += 1
}

///|
/// Emits a literal run.
fn Encoder::emit_literal(
  self : Encoder,
  data : BytesView,
  offset : Int,
  length : Int,
) -> Unit {
  let n = length - 1
  if n < 60 {
    self.ensure_capacity(1 + length)
    self.out_buf.unsafe_set(self.out_pos, ((n << 2) | TAG_LITERAL).to_byte())
    self.out_pos += 1
  } else if n < 0x100 {
    self.ensure_capacity(2 + length)
    self.out_buf.unsafe_set(self.out_pos, ((60 << 2) | TAG_LITERAL).to_byte())
    self.out_buf.unsafe_set(self.out_pos + 1, n.to_byte())
    self.out_pos += 2
  } else if n < 0x10000 {
    self.ensure_capacity(3 + length)
    self.out_buf.unsafe_set(self.out_pos, ((61 << 2) | TAG_LITERAL).to_byte())
    self.out_buf.unsafe_set(self.out_pos + 1, (n & 0xFF).to_byte())
    self.out_buf.unsafe_set(self.out_pos + 2, ((n >> 8) & 0xFF).to_byte())
    self.out_pos += 3
  } else if n < 0x1000000 {
    self.ensure_capacity(4 + length)
    self.out_buf.unsafe_set(self.out_pos, ((62 << 2) | TAG_LITERAL).to_byte())
    self.out_buf.unsafe_set(self.out_pos + 1, (n & 0xFF).to_byte())
    self.out_buf.unsafe_set(self.out_pos + 2, ((n >> 8) & 0xFF).to_byte())
    self.out_buf.unsafe_set(self.out_pos + 3, ((n >> 16) & 0xFF).to_byte())
    self.out_pos += 4
  } else {
    self.ensure_capacity(5 + length)
    self.out_buf.unsafe_set(self.out_pos, ((63 << 2) | TAG_LITERAL).to_byte())
    self.out_buf.unsafe_set(self.out_pos + 1, (n & 0xFF).to_byte())
    self.out_buf.unsafe_set(self.out_pos + 2, ((n >> 8) & 0xFF).to_byte())
    self.out_buf.unsafe_set(self.out_pos + 3, ((n >> 16) & 0xFF).to_byte())
    self.out_buf.unsafe_set(self.out_pos + 4, ((n >> 24) & 0xFF).to_byte())
    self.out_pos += 5
  }
  // Copy literal bytes
  for i in 0..<length {
    self.out_buf.unsafe_set(self.out_pos + i, data.unsafe_get(offset + i))
  }
  self.out_pos += length
}

///|
/// Emits a copy (back-reference).
fn Encoder::emit_copy(self : Encoder, offset_ : Int, length_ : Int) -> Unit {
  let offset = offset_
  let mut length = length_
  // Emit copy2 for lengths > 64 or offsets > 2047
  while length >= 68 {
    self.ensure_capacity(3)
    self.out_buf.unsafe_set(self.out_pos, ((63 << 2) | TAG_COPY2).to_byte())
    self.out_buf.unsafe_set(self.out_pos + 1, (offset & 0xFF).to_byte())
    self.out_buf.unsafe_set(self.out_pos + 2, ((offset >> 8) & 0xFF).to_byte())
    self.out_pos += 3
    length -= 64
  }
  if length > 64 {
    self.ensure_capacity(3)
    let len_field = length - 61
    self.out_buf.unsafe_set(
      self.out_pos,
      ((len_field << 2) | TAG_COPY2).to_byte(),
    )
    self.out_buf.unsafe_set(self.out_pos + 1, (offset & 0xFF).to_byte())
    self.out_buf.unsafe_set(self.out_pos + 2, ((offset >> 8) & 0xFF).to_byte())
    self.out_pos += 3
    return
  }
  if length >= 12 || offset >= 2048 {
    self.ensure_capacity(3)
    self.out_buf.unsafe_set(
      self.out_pos,
      (((length - 1) << 2) | TAG_COPY2).to_byte(),
    )
    self.out_buf.unsafe_set(self.out_pos + 1, (offset & 0xFF).to_byte())
    self.out_buf.unsafe_set(self.out_pos + 2, ((offset >> 8) & 0xFF).to_byte())
    self.out_pos += 3
  } else {
    // Use copy1 (2-byte encoding) for short copies with small offsets
    self.ensure_capacity(2)
    self.out_buf.unsafe_set(
      self.out_pos,
      ((offset >> 8 << 5) | ((length - 4) << 2) | TAG_COPY1).to_byte(),
    )
    self.out_buf.unsafe_set(self.out_pos + 1, (offset & 0xFF).to_byte())
    self.out_pos += 2
  }
}

///|
fn snappy_hash(data : BytesView, pos : Int) -> Int {
  let u = data.unsafe_get(pos).to_int() |
    (data.unsafe_get(pos + 1).to_int() << 8) |
    (data.unsafe_get(pos + 2).to_int() << 16) |
    (data.unsafe_get(pos + 3).to_int() << 24)
  // Knuth multiplicative hash
  ((u * 0x1E35A7BD) >> 18) & HASH_TABLE_MASK
}

///|
fn Encoder::write(self : Encoder, data : BytesView) -> Unit {
  let len = data.length()
  if len == 0 {
    self.emit_varint(0)
    return
  }
  // Emit uncompressed length as varint
  self.emit_varint(len)
  // Process in blocks up to MAX_BLOCK_SIZE
  let mut block_start = 0
  while block_start < len {
    let block_end = if block_start + MAX_BLOCK_SIZE < len {
      block_start + MAX_BLOCK_SIZE
    } else {
      len
    }
    self.compress_block(data, block_start, block_end)
    block_start = block_end
  }
}

///|
fn Encoder::compress_block(
  self : Encoder,
  data : BytesView,
  block_start : Int,
  block_end : Int,
) -> Unit {
  let block_len = block_end - block_start
  if block_len < 4 {
    self.emit_literal(data, block_start, block_len)
    return
  }
  // Clear hash table
  let table = self.table
  for i in 0..<HASH_TABLE_SIZE {
    table.unsafe_set(i, 0)
  }
  let mut ip = block_start // current position
  let mut next_emit = block_start // start of pending literal
  let ip_limit = block_end - 4 // can't hash last 3 bytes
  let mut next_hash = snappy_hash(data, ip)
  while ip <= ip_limit {
    let hash = next_hash
    let candidate = table.unsafe_get(hash) + block_start
    table.unsafe_set(hash, ip - block_start)
    if ip + 1 <= ip_limit {
      next_hash = snappy_hash(data, ip + 1)
    }
    // Check match (ip == candidate guards against self-match from zero-init table)
    if candidate < block_start ||
      ip == candidate ||
      ip - candidate >= MAX_BLOCK_SIZE ||
      data.unsafe_get(ip) != data.unsafe_get(candidate) ||
      data.unsafe_get(ip + 1) != data.unsafe_get(candidate + 1) ||
      data.unsafe_get(ip + 2) != data.unsafe_get(candidate + 2) ||
      data.unsafe_get(ip + 3) != data.unsafe_get(candidate + 3) {
      ip += 1
      continue
    }
    // Found a match - emit pending literal
    if next_emit < ip {
      self.emit_literal(data, next_emit, ip - next_emit)
    }
    // Extend the match
    let mut match_len = 4
    while ip + match_len < block_end &&
          data.unsafe_get(ip + match_len) ==
          data.unsafe_get(candidate + match_len) {
      match_len += 1
    }
    self.emit_copy(ip - candidate, match_len)
    ip += match_len
    next_emit = ip
    if ip <= ip_limit {
      next_hash = snappy_hash(data, ip)
    }
  }
  // Emit any trailing literal
  if next_emit < block_end {
    self.emit_literal(data, next_emit, block_end - next_emit)
  }
}

///|
fn Encoder::close(self : Encoder) -> Bytes {
  let result = @blit.make_uninit(self.out_pos)
  @blit.blit_fixed_array(result, 0, self.out_buf, 0, self.out_pos)
  result.unsafe_reinterpret_as_bytes()
}
