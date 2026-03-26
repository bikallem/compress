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
  buf : @blit.Buffer
  table : FixedArray[Int] // hash table: hash -> position in input
}

///|
fn Encoder::new() -> Encoder {
  {
    buf: @blit.Buffer::new(size_hint=4096),
    table: FixedArray::make(HASH_TABLE_SIZE, 0),
  }
}

///|
/// Encodes the uncompressed length as a varint at the start.
fn Encoder::emit_varint(self : Encoder, n_ : Int) -> Unit {
  let mut n = n_
  self.buf.ensure_capacity(5)
  while n >= 128 {
    self.buf.write_byte_unchecked(((n & 0x7F) | 0x80).to_byte())
    n = n >> 7
  }
  self.buf.write_byte_unchecked(n.to_byte())
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
  let hdr_size = if n < 60 {
    1
  } else if n < 0x100 {
    2
  } else if n < 0x10000 {
    3
  } else if n < 0x1000000 {
    4
  } else {
    5
  }
  self.buf.ensure_capacity(hdr_size + length)
  let out = self.buf.data()
  let pos = self.buf.length()
  if n < 60 {
    out.unsafe_set(pos, ((n << 2) | TAG_LITERAL).to_byte())
  } else if n < 0x100 {
    out.unsafe_set(pos, ((60 << 2) | TAG_LITERAL).to_byte())
    out.unsafe_set(pos + 1, n.to_byte())
  } else if n < 0x10000 {
    out.unsafe_set(pos, ((61 << 2) | TAG_LITERAL).to_byte())
    out.unsafe_set(pos + 1, (n & 0xFF).to_byte())
    out.unsafe_set(pos + 2, ((n >> 8) & 0xFF).to_byte())
  } else if n < 0x1000000 {
    out.unsafe_set(pos, ((62 << 2) | TAG_LITERAL).to_byte())
    out.unsafe_set(pos + 1, (n & 0xFF).to_byte())
    out.unsafe_set(pos + 2, ((n >> 8) & 0xFF).to_byte())
    out.unsafe_set(pos + 3, ((n >> 16) & 0xFF).to_byte())
  } else {
    out.unsafe_set(pos, ((63 << 2) | TAG_LITERAL).to_byte())
    out.unsafe_set(pos + 1, (n & 0xFF).to_byte())
    out.unsafe_set(pos + 2, ((n >> 8) & 0xFF).to_byte())
    out.unsafe_set(pos + 3, ((n >> 16) & 0xFF).to_byte())
    out.unsafe_set(pos + 4, ((n >> 24) & 0xFF).to_byte())
  }
  let lit_pos = pos + hdr_size
  for i in 0..<length {
    out.unsafe_set(lit_pos + i, data.unsafe_get(offset + i))
  }
  self.buf.unsafe_advance(hdr_size + length)
}

///|
/// Emits a copy (back-reference).
fn Encoder::emit_copy(self : Encoder, offset : Int, length_ : Int) -> Unit {
  let mut length = length_
  // Emit copy2 for lengths > 64 or offsets > 2047
  if length >= 68 {
    let num_full = (length - 4) / 64
    self.buf.ensure_capacity(num_full * 3 + 3)
    while length >= 68 {
      self.buf.write_byte_unchecked(((63 << 2) | TAG_COPY2).to_byte())
      self.buf.write_byte_unchecked((offset & 0xFF).to_byte())
      self.buf.write_byte_unchecked(((offset >> 8) & 0xFF).to_byte())
      length -= 64
    }
  }
  if length > 64 {
    self.buf.ensure_capacity(3)
    let len_field = length - 61
    self.buf.write_byte_unchecked(((len_field << 2) | TAG_COPY2).to_byte())
    self.buf.write_byte_unchecked((offset & 0xFF).to_byte())
    self.buf.write_byte_unchecked(((offset >> 8) & 0xFF).to_byte())
    return
  }
  if length >= 12 || offset >= 2048 {
    self.buf.ensure_capacity(3)
    self.buf.write_byte_unchecked((((length - 1) << 2) | TAG_COPY2).to_byte())
    self.buf.write_byte_unchecked((offset & 0xFF).to_byte())
    self.buf.write_byte_unchecked(((offset >> 8) & 0xFF).to_byte())
  } else {
    self.buf.ensure_capacity(2)
    self.buf.write_byte_unchecked(
      ((offset >> 8 << 5) | ((length - 4) << 2) | TAG_COPY1).to_byte(),
    )
    self.buf.write_byte_unchecked((offset & 0xFF).to_byte())
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
  self.buf.to_bytes()
}

///|
fn Encoder::take_output(self : Encoder) -> Bytes {
  if self.buf.length() == 0 {
    return Bytes::default()
  }
  let out = self.buf.to_bytes()
  self.buf.reset()
  out
}
