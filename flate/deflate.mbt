///|
/// Compresses data using DEFLATE (RFC 1951).
pub fn compress(
  data : Bytes,
  level? : CompressionLevel = DefaultCompression,
) -> Bytes raise CompressError {
  compress_with_dict(data, Bytes::default(), level~)
}

///|
/// Compresses data using DEFLATE with a preset dictionary.
pub fn compress_with_dict(
  data : Bytes,
  _dict : Bytes,
  level? : CompressionLevel = DefaultCompression,
) -> Bytes raise CompressError {
  let lvl = level.to_int()
  guard lvl >= -2 && lvl <= 9 else { raise CompressError::InvalidLevel(lvl) }
  if lvl == 0 {
    return deflate_stored(data)
  }
  deflate_lz77(data, lvl)
}

///|
/// Emits stored (uncompressed) DEFLATE blocks.
fn deflate_stored(data : Bytes) -> Bytes {
  let buf = @buffer.new(size_hint=data.length() + 11)
  let mut offset = 0
  while offset < data.length() || offset == 0 {
    let remaining = data.length() - offset
    let block_len = if remaining > 65535 { 65535 } else { remaining }
    let is_final = offset + block_len >= data.length()
    // Block header: BFINAL(1) BTYPE(00)
    buf.write_byte(if is_final { b'\x01' } else { b'\x00' })
    // LEN (16-bit LE)
    buf.write_byte((block_len & 0xFF).to_byte())
    buf.write_byte((block_len >> 8).to_byte())
    // NLEN (one's complement of LEN)
    let nlen = block_len ^ 0xFFFF
    buf.write_byte((nlen & 0xFF).to_byte())
    buf.write_byte((nlen >> 8).to_byte())
    // Data
    for i in offset..<(offset + block_len) {
      buf.write_byte(data[i])
    }
    offset += block_len
    if data.length() == 0 {
      break
    }
  }
  buf.to_bytes()
}

///|
/// Precomputed reversed fixed Huffman literal codes.
/// Entry format: (reversed_code << 4) | code_length
/// For symbols 0-143: 8-bit codes, for 144-255: 9-bit codes
let fixed_lit_codes : ReadOnlyArray[UInt] = {
  let t = FixedArray::make(286, 0U)
  for sym in 0..<=143 {
    let code = sym + 0x30
    t[sym] = (reverse_uint_8(code.reinterpret_as_uint()) << 4) | 8U
  }
  for sym in 144..<=255 {
    let code = sym - 144 + 0x190
    t[sym] = (reverse_uint_9(code.reinterpret_as_uint()) << 4) | 9U
  }
  // Length codes 256-279: 7-bit codes
  for sym in 256..<=279 {
    let code = sym - 256
    t[sym] = (reverse_uint_7(code.reinterpret_as_uint()) << 4) | 7U
  }
  // Length codes 280-285: 8-bit codes
  for sym in 280..<=285 {
    let code = sym - 280 + 0xC0
    t[sym] = (reverse_uint_8(code.reinterpret_as_uint()) << 4) | 8U
  }
  ReadOnlyArray::from_array(t[:])
}

///|
/// Precomputed reversed 5-bit distance codes.
let fixed_dist_codes : ReadOnlyArray[UInt] = {
  let t = FixedArray::make(30, 0U)
  for i in 0..<30 {
    t[i] = reverse_uint_5(i.reinterpret_as_uint())
  }
  ReadOnlyArray::from_array(t[:])
}

///|
/// Precomputed length encoding table.
/// Entry format: (length_code, extra_bits, extra_value) packed into FixedArray
/// Index: length - MIN_MATCH_LENGTH (0-255 for lengths 3-258)
let length_encode_table : ReadOnlyArray[Int] = {
  let size = MAX_MATCH_LENGTH - MIN_MATCH_LENGTH + 1
  let t = FixedArray::make(size * 3, 0)
  for length in MIN_MATCH_LENGTH..<=MAX_MATCH_LENGTH {
    let idx = length - MIN_MATCH_LENGTH
    let mut found = false
    for i in 0..<length_base.length() {
      let next_base = if i + 1 < length_base.length() {
        length_base[i + 1]
      } else {
        259
      }
      if length >= length_base[i] && length < next_base {
        t[idx * 3] = 257 + i
        t[idx * 3 + 1] = length_extra[i]
        t[idx * 3 + 2] = length - length_base[i]
        found = true
        break
      }
    }
    if not(found) {
      t[idx * 3] = 285
      t[idx * 3 + 1] = 0
      t[idx * 3 + 2] = 0
    }
  }
  ReadOnlyArray::from_array(t[:])
}

///|
/// Precomputed distance encoding table.
/// For each distance 1-32768, stores (dist_code, extra_bits, extra_value)
/// Uses binary search for O(1) lookup.
let dist_encode_table : ReadOnlyArray[Int] = {
  // Store (dist_code, extra_bits) for each distance 1..32768
  // We only need dist_code for each distance; extra_value = dist - dist_base[code]
  let size = MAX_MATCH_OFFSET
  let t = FixedArray::make(size * 2, 0)
  for d in 1..<=MAX_MATCH_OFFSET {
    for i = 0; i < dist_base.length(); i = i + 1 {
      let next_base = if i + 1 < dist_base.length() {
        dist_base[i + 1]
      } else {
        32769
      }
      if d >= dist_base[i] && d < next_base {
        t[(d - 1) * 2] = i
        t[(d - 1) * 2 + 1] = dist_extra[i]
        break
      }
    }
  }
  ReadOnlyArray::from_array(t[:])
}

///|
/// DEFLATE compression using LZ77 with optimal Huffman coding.
fn deflate_lz77(data : Bytes, level : Int) -> Bytes {
  let w = DeflateWriter::new(size_hint=data.length())
  if data.length() == 0 {
    w.start_fixed_block(true)
    w.write_fixed_symbol(END_BLOCK_MARKER)
    return w.finish()
  }
  if level <= 1 {
    // Single-pass: write fixed Huffman directly, no token collection
    return deflate_fast_direct(data, w)
  }
  let tokens = if level <= 3 {
    deflate_greedy_tokens(data, level)
  } else {
    deflate_lazy_tokens(data, level)
  }
  w.write_dynamic_block(tokens, true)
  w.finish()
}

///|
/// Single-pass level 1: hash, match, and emit fixed Huffman codes in one pass.
fn deflate_fast_direct(data : Bytes, w : DeflateWriter) -> Bytes {
  let data_len = data.length()
  let hash_size = 1 << 15
  let hash_mask = hash_size - 1
  let head = FixedArray::make(hash_size, -1)
  w.start_fixed_block(true)
  let mut i = 0
  while i < data_len {
    if i + 2 < data_len {
      let h = hash4(data, i) & hash_mask
      let match_pos = head[h]
      head[h] = i
      if match_pos >= 0 && i - match_pos <= MAX_MATCH_OFFSET {
        let max_len = if data_len - i < MAX_MATCH_LENGTH {
          data_len - i
        } else {
          MAX_MATCH_LENGTH
        }
        let mut length = 0
        while length < max_len && data[i + length] == data[match_pos + length] {
          length += 1
        }
        if length >= MIN_MATCH_LENGTH {
          w.write_match_fast(length, i - match_pos)
          if i + 1 + 2 < data_len {
            let h1 = hash4(data, i + 1) & hash_mask
            head[h1] = i + 1
          }
          i += length
          continue
        }
      }
    }
    w.write_literal_fast(data[i])
    i += 1
  }
  w.write_fixed_symbol(END_BLOCK_MARKER)
  w.finish()
}

///|
/// Greedy encoder for levels 2-3: hash chains, take first good match.
fn deflate_greedy_tokens(data : Bytes, level : Int) -> Array[Token] {
  let tokens : Array[Token] = []
  let data_len = data.length()
  let window_size = 1 << 15
  let window_mask = window_size - 1
  let hash_size = 1 << 15
  let hash_mask = hash_size - 1
  let max_chain = if level == 2 { 8 } else { 16 }
  let head = FixedArray::make(hash_size, -1)
  let prev = FixedArray::make(window_size, -1)
  let mut i = 0
  while i < data_len {
    if i + 2 < data_len {
      let h = hash4(data, i) & hash_mask
      let match_head = head[h]
      prev[i & window_mask] = match_head
      head[h] = i
      if match_head >= 0 && i - match_head <= MAX_MATCH_OFFSET {
        let (length, offset) = find_best_match(
          data, i, match_head, prev, window_mask, max_chain,
        )
        if length >= MIN_MATCH_LENGTH {
          tokens.push(Token::match_(length, offset))
          for j in 1..<length {
            if i + j + 2 < data_len {
              let hj = hash4(data, i + j) & hash_mask
              prev[(i + j) & window_mask] = head[hj]
              head[hj] = i + j
            }
          }
          i += length
          continue
        }
      }
    }
    tokens.push(Token::literal(data[i]))
    i += 1
  }
  tokens
}

///|
/// Lazy matching encoder for levels 4+: tries next position before committing.
fn deflate_lazy_tokens(data : Bytes, level : Int) -> Array[Token] {
  let tokens : Array[Token] = []
  let data_len = data.length()
  let window_size = 1 << 15
  let window_mask = window_size - 1
  let hash_size = 1 << 15
  let hash_mask = hash_size - 1
  let max_chain = match level {
    4 => 32
    5 => 64
    6 => 128
    7 => 256
    8 => 512
    _ => 1024
  }
  let head = FixedArray::make(hash_size, -1)
  let prev = FixedArray::make(window_size, -1)
  let mut i = 0
  let mut prev_match_len = 0
  let mut prev_match_dist = 0
  let mut prev_literal : Byte = b'\x00'
  let mut has_prev = false
  while i < data_len {
    let mut cur_len = 0
    let mut cur_dist = 0
    if i + 2 < data_len {
      let h = hash4(data, i) & hash_mask
      let match_head = head[h]
      prev[i & window_mask] = match_head
      head[h] = i
      if match_head >= 0 && i - match_head <= MAX_MATCH_OFFSET {
        let (length, offset) = find_best_match(
          data, i, match_head, prev, window_mask, max_chain,
        )
        if length >= MIN_MATCH_LENGTH {
          cur_len = length
          cur_dist = offset
        }
      }
    }
    if has_prev {
      if cur_len > prev_match_len + 1 {
        // Current match is better — emit previous as literal, keep current
        tokens.push(Token::literal(prev_literal))
        prev_match_len = cur_len
        prev_match_dist = cur_dist
        prev_literal = data[i]
        i += 1
      } else {
        // Previous match is good enough — emit it
        tokens.push(Token::match_(prev_match_len, prev_match_dist))
        // Update hash chains for skipped bytes (starting from byte after prev literal)
        let start = i
        let end = start + prev_match_len - 1 // -1 because we already hashed position i
        for j in start..<end {
          if j + 2 < data_len {
            let hj = hash4(data, j) & hash_mask
            prev[j & window_mask] = head[hj]
            head[hj] = j
          }
        }
        i = end
        has_prev = false
      }
    } else if cur_len >= MIN_MATCH_LENGTH {
      // Defer: try next position for a better match
      has_prev = true
      prev_match_len = cur_len
      prev_match_dist = cur_dist
      prev_literal = data[i]
      i += 1
    } else {
      tokens.push(Token::literal(data[i]))
      i += 1
    }
  }
  if has_prev {
    // Flush deferred match
    tokens.push(Token::match_(prev_match_len, prev_match_dist))
  }
  tokens
}

///|
/// Improved hash function using 4-byte input and multiplicative hashing.
fn hash4(data : Bytes, i : Int) -> Int {
  let b0 = data[i].to_int()
  let b1 = data[i + 1].to_int()
  let b2 = data[i + 2].to_int()
  (b0 | (b1 << 8) | (b2 << 16)) ^ (b2 * 0x1e35a7bd)
}

///|
fn find_best_match(
  data : Bytes,
  cur : Int,
  match_head : Int,
  prev : FixedArray[Int],
  window_mask : Int,
  max_chain : Int,
) -> (Int, Int) {
  let mut best_len = MIN_MATCH_LENGTH - 1
  let mut best_offset = 0
  let mut pos = match_head
  let mut chain_count = 0
  let data_len = data.length()
  let max_len = if data_len - cur < MAX_MATCH_LENGTH {
    data_len - cur
  } else {
    MAX_MATCH_LENGTH
  }
  while pos >= 0 && cur - pos <= MAX_MATCH_OFFSET && chain_count < max_chain {
    // Quick rejection: check last byte of best match first
    if best_len > 0 && data[pos + best_len] != data[cur + best_len] {
      let next = prev[pos & window_mask]
      if next >= pos {
        break
      }
      pos = next
      chain_count += 1
      continue
    }
    // Count matching bytes
    let mut length = 0
    while length < max_len && data[cur + length] == data[pos + length] {
      length += 1
    }
    if length > best_len {
      best_len = length
      best_offset = cur - pos
      if best_len == max_len {
        break
      }
    }
    let next = prev[pos & window_mask]
    if next >= pos {
      break
    }
    pos = next
    chain_count += 1
  }
  if best_offset > 0 && best_len >= MIN_MATCH_LENGTH {
    (best_len, best_offset)
  } else {
    (0, 0)
  }
}

///|
/// Internal bit writer for DEFLATE output.
priv struct DeflateWriter {
  buf : @buffer.Buffer
  mut bits : UInt64
  mut n_bits : Int
}

///|
fn DeflateWriter::new(size_hint? : Int = 256) -> DeflateWriter {
  { buf: @buffer.new(size_hint~), bits: 0UL, n_bits: 0 }
}

///|
fn DeflateWriter::write_bits_lsb(
  self : DeflateWriter,
  val : UInt,
  n : Int,
) -> Unit {
  self.bits = self.bits | (val.to_uint64() << self.n_bits)
  self.n_bits += n
  while self.n_bits >= 8 {
    self.buf.write_byte((self.bits & 0xFFUL).to_byte())
    self.bits = self.bits >> 8
    self.n_bits -= 8
  }
}

///|
fn DeflateWriter::start_fixed_block(
  self : DeflateWriter,
  is_final : Bool,
) -> Unit {
  let header = if is_final { 0b011U } else { 0b010U }
  self.write_bits_lsb(header, 3)
}

///|
/// Write a literal byte using precomputed table.
fn DeflateWriter::write_literal_fast(self : DeflateWriter, b : Byte) -> Unit {
  let entry = fixed_lit_codes[b.to_int()]
  let code = entry >> 4
  let n = (entry & 0xFU).reinterpret_as_int()
  self.write_bits_lsb(code, n)
}

///|
/// Write a fixed Huffman symbol (literal, length code, or end-of-block) using precomputed table.
fn DeflateWriter::write_fixed_symbol(self : DeflateWriter, sym : Int) -> Unit {
  let entry = fixed_lit_codes[sym]
  let code = entry >> 4
  let n = (entry & 0xFU).reinterpret_as_int()
  // Write block header for end-of-block if needed
  self.write_bits_lsb(code, n)
}

///|
/// Write a match using precomputed tables.
fn DeflateWriter::write_match_fast(
  self : DeflateWriter,
  length : Int,
  offset : Int,
) -> Unit {
  // Encode length using precomputed table
  let lidx = (length - MIN_MATCH_LENGTH) * 3
  let length_code = length_encode_table[lidx]
  let length_extra_bits = length_encode_table[lidx + 1]
  let length_extra_val = length_encode_table[lidx + 2]
  // Write length code using precomputed reversed code
  let lentry = fixed_lit_codes[length_code]
  let lcode = lentry >> 4
  let ln = (lentry & 0xFU).reinterpret_as_int()
  self.write_bits_lsb(lcode, ln)
  if length_extra_bits > 0 {
    self.write_bits_lsb(
      length_extra_val.reinterpret_as_uint(),
      length_extra_bits,
    )
  }
  // Encode distance using precomputed table
  let didx = (offset - 1) * 2
  let dist_code = dist_encode_table[didx]
  let dist_extra_bits = dist_encode_table[didx + 1]
  let dist_extra_val = offset - dist_base[dist_code]
  // Write distance code using precomputed reversed code
  self.write_bits_lsb(fixed_dist_codes[dist_code], 5)
  if dist_extra_bits > 0 {
    self.write_bits_lsb(dist_extra_val.reinterpret_as_uint(), dist_extra_bits)
  }
}

///|
fn DeflateWriter::finish(self : DeflateWriter) -> Bytes {
  if self.n_bits > 0 {
    self.buf.write_byte((self.bits & 0xFFUL).to_byte())
  }
  self.buf.to_bytes()
}

///|
/// Reverse lowest 5 bits.
fn reverse_uint_5(val : UInt) -> UInt {
  let mut result = 0U
  let mut v = val
  result = (result << 1) | (v & 1U)
  v = v >> 1
  result = (result << 1) | (v & 1U)
  v = v >> 1
  result = (result << 1) | (v & 1U)
  v = v >> 1
  result = (result << 1) | (v & 1U)
  v = v >> 1
  result = (result << 1) | (v & 1U)
  ignore(v)
  result
}

///|
/// Reverse lowest 7 bits.
fn reverse_uint_7(val : UInt) -> UInt {
  let mut result = 0U
  let mut v = val
  for _ in 0..<7 {
    result = (result << 1) | (v & 1U)
    v = v >> 1
  }
  result
}

///|
/// Reverse lowest 8 bits.
fn reverse_uint_8(val : UInt) -> UInt {
  let mut result = 0U
  let mut v = val
  for _ in 0..<8 {
    result = (result << 1) | (v & 1U)
    v = v >> 1
  }
  result
}

///|
/// Reverse lowest 9 bits.
fn reverse_uint_9(val : UInt) -> UInt {
  let mut result = 0U
  let mut v = val
  for _ in 0..<9 {
    result = (result << 1) | (v & 1U)
    v = v >> 1
  }
  result
}

///|
fn reverse_uint(val : UInt, n : Int) -> UInt {
  let mut result = 0U
  let mut v = val
  for _ in 0..<n {
    result = (result << 1) | (v & 1U)
    v = v >> 1
  }
  result
}

///|
fn _encode_length(length : Int) -> (Int, Int, Int) {
  let idx = (length - MIN_MATCH_LENGTH) * 3
  (
    length_encode_table[idx],
    length_encode_table[idx + 1],
    length_encode_table[idx + 2],
  )
}

///|
fn _encode_distance(dist : Int) -> (Int, Int, Int) {
  let didx = (dist - 1) * 2
  let dist_code = dist_encode_table[didx]
  let dist_extra_bits = dist_encode_table[didx + 1]
  let dist_extra_val = dist - dist_base[dist_code]
  (dist_code, dist_extra_bits, dist_extra_val)
}
