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
/// DEFLATE compression using LZ77 with fixed Huffman codes.
fn deflate_lz77(data : Bytes, _level : Int) -> Bytes {
  let w = DeflateWriter::new()
  if data.length() == 0 {
    // Empty: emit final empty fixed block
    w.write_fixed_bits(end_block_marker, true)
    return w.finish()
  }
  // For simplicity, emit a single final block with fixed Huffman encoding.
  // Process data using LZ77 string matching with a hash table.
  let window_bits = 15
  let window_size = 1 << window_bits
  let window_mask = window_size - 1
  let hash_bits = 15
  let hash_size = 1 << hash_bits
  let hash_mask = hash_size - 1
  // Hash chain arrays
  let head = FixedArray::make(hash_size, -1) // hash -> most recent position
  let prev = FixedArray::make(window_size, -1) // chain links
  // Start final block with fixed Huffman
  w.start_fixed_block(true)
  let mut i = 0
  while i < data.length() {
    if i + 2 < data.length() {
      // Compute hash of 3-byte sequence
      let h = hash3(data, i) & hash_mask
      let match_head = head[h]
      prev[i & window_mask] = match_head
      head[h] = i
      // Try to find a match
      if match_head >= 0 && i - match_head <= max_match_offset {
        let (length, offset) = find_best_match(
          data, i, match_head, prev, window_mask,
        )
        if length >= min_match_length {
          w.write_match(length, offset)
          // Update hash chains for bytes in the match
          for j in 1..<length {
            if i + j + 2 < data.length() {
              let hj = hash3(data, i + j) & hash_mask
              prev[(i + j) & window_mask] = head[hj]
              head[hj] = i + j
            }
          }
          i += length
          continue
        }
      }
    }
    // Emit literal
    w.write_literal(data[i])
    i += 1
  }
  w.write_fixed_bits(end_block_marker, false)
  w.finish()
}

///|
fn hash3(data : Bytes, i : Int) -> Int {
  let b0 = data[i].to_int()
  let b1 = data[i + 1].to_int()
  let b2 = data[i + 2].to_int()
  (b0 | (b1 << 8) | (b2 << 16)) * 0x1e35a7bd
}

///|
fn find_best_match(
  data : Bytes,
  cur : Int,
  match_head : Int,
  prev : FixedArray[Int],
  window_mask : Int,
) -> (Int, Int) {
  let mut best_len = min_match_length - 1
  let mut best_offset = 0
  let mut pos = match_head
  let max_chain = 128
  let mut chain_count = 0
  let max_len = if data.length() - cur < max_match_length {
    data.length() - cur
  } else {
    max_match_length
  }
  while pos >= 0 && cur - pos <= max_match_offset && chain_count < max_chain {
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
      break // avoid infinite loops
    }
    pos = next
    chain_count += 1
  }
  if best_offset > 0 && best_len >= min_match_length {
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
fn DeflateWriter::new() -> DeflateWriter {
  { buf: @buffer.new(size_hint=256), bits: 0UL, n_bits: 0 }
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
  // BFINAL (1 bit) + BTYPE=01 (2 bits) = fixed Huffman
  let header = if is_final { 0b011U } else { 0b010U }
  self.write_bits_lsb(header, 3)
}

///|
fn DeflateWriter::write_literal(self : DeflateWriter, b : Byte) -> Unit {
  let sym = b.to_int()
  // Fixed Huffman: literals 0-143 are 8-bit codes starting at 0b00110000 (reversed)
  // literals 144-255 are 9-bit codes starting at 0b110010000 (reversed)
  if sym <= 143 {
    // 8-bit code: value = sym + 0x30, bit-reversed
    let code = sym + 0x30
    self.write_bits_lsb(reverse_uint(code.reinterpret_as_uint(), 8), 8)
  } else {
    // 9-bit code: value = sym - 144 + 0x190, bit-reversed
    let code = sym - 144 + 0x190
    self.write_bits_lsb(reverse_uint(code.reinterpret_as_uint(), 9), 9)
  }
}

///|
fn DeflateWriter::write_fixed_bits(
  self : DeflateWriter,
  sym : Int,
  is_end_with_header : Bool,
) -> Unit {
  if is_end_with_header {
    // Write final block header + end marker together
    // BFINAL=1, BTYPE=01 (fixed)
    self.write_bits_lsb(0b011U, 3)
  }
  if sym == end_block_marker {
    // Fixed Huffman: symbol 256 is 7-bit code 0b0000000
    // Codes 256-279: 7-bit starting at 0
    let code = sym - 256
    self.write_bits_lsb(reverse_uint(code.reinterpret_as_uint(), 7), 7)
  }
}

///|
fn DeflateWriter::write_match(
  self : DeflateWriter,
  length : Int,
  offset : Int,
) -> Unit {
  // Encode length
  let (length_code, length_extra_bits, length_extra_val) = encode_length(length)
  // Length codes 257-279: 7-bit fixed Huffman codes (0..23)
  // Length codes 280-285: 8-bit fixed Huffman codes
  if length_code <= 279 {
    let code = length_code - 256
    self.write_bits_lsb(reverse_uint(code.reinterpret_as_uint(), 7), 7)
  } else {
    let code = length_code - 280 + 0xC0
    self.write_bits_lsb(reverse_uint(code.reinterpret_as_uint(), 8), 8)
  }
  if length_extra_bits > 0 {
    self.write_bits_lsb(
      length_extra_val.reinterpret_as_uint(),
      length_extra_bits,
    )
  }
  // Encode distance (5-bit fixed codes + extra bits)
  let (dist_code, dist_extra_bits, dist_extra_val) = encode_distance(offset)
  self.write_bits_lsb(reverse_uint(dist_code.reinterpret_as_uint(), 5), 5)
  if dist_extra_bits > 0 {
    self.write_bits_lsb(dist_extra_val.reinterpret_as_uint(), dist_extra_bits)
  }
}

///|
fn DeflateWriter::finish(self : DeflateWriter) -> Bytes {
  // Flush remaining bits
  if self.n_bits > 0 {
    self.buf.write_byte((self.bits & 0xFFUL).to_byte())
  }
  self.buf.to_bytes()
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
fn encode_length(length : Int) -> (Int, Int, Int) {
  // Returns (length_code, extra_bits, extra_value)
  for i in 0..<length_base.length() {
    let next_base = if i + 1 < length_base.length() {
      length_base[i + 1]
    } else {
      259
    }
    if length >= length_base[i] && length < next_base {
      return (257 + i, length_extra[i], length - length_base[i])
    }
  }
  // Should not reach here for valid lengths
  (285, 0, 0)
}

///|
fn encode_distance(dist : Int) -> (Int, Int, Int) {
  // Returns (dist_code, extra_bits, extra_value)
  for i in 0..<dist_base.length() {
    let next_base = if i + 1 < dist_base.length() {
      dist_base[i + 1]
    } else {
      32769
    }
    if dist >= dist_base[i] && dist < next_base {
      return (i, dist_extra[i], dist - dist_base[i])
    }
  }
  (29, 13, dist - dist_base[29])
}
