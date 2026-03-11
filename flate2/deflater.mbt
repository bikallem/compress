///|
/// Phase of the deflate state machine.
priv enum DeflatePhase {
  Ready
  Finished
  Failed(CompressError)
}

///|
/// Streaming, non-blocking DEFLATE compressor.
///
/// The caller drives the encode loop:
///   - `encode(Some(data))` feeds input, may return `Data(bytes)` or `Ok`
///   - `encode(None)` signals EOF, may return `Data(bytes)` or `End`
pub struct Deflater {
  priv level : Int
  priv mut phase : DeflatePhase
  priv input_chunks : Array[Bytes]
  priv mut total_input : Int
  priv mut pending_output : Bytes
}

///|
pub fn Deflater::new(
  level? : CompressionLevel = DefaultCompression,
) -> Deflater {
  let lvl = level.to_int()
  {
    level: lvl,
    phase: Ready,
    input_chunks: [],
    total_input: 0,
    pending_output: Bytes::default(),
  }
}

///|
/// Single entry point for encoding.
///   encode(Some(data)) — feed input to compress
///   encode(None)       — signal end of input, flush final block
pub fn Deflater::encode(self : Deflater, data : Bytes?) -> Encode {
  // Emit pending output first
  if self.pending_output.length() > 0 {
    let out = self.pending_output
    self.pending_output = Bytes::default()
    return Data(out)
  }
  match self.phase {
    Failed(e) => Error(e)
    Finished => End
    Ready =>
      match data {
        Some(chunk) => {
          if chunk.length() > 0 {
            self.input_chunks.push(chunk)
            self.total_input += chunk.length()
          }
          Ok
        }
        None => self.do_compress()
      }
  }
}

///|
fn Deflater::do_compress(self : Deflater) -> Encode {
  let lvl = self.level
  if lvl < -2 || lvl > 9 {
    self.phase = Failed(CompressError::InvalidLevel(lvl))
    return Error(CompressError::InvalidLevel(lvl))
  }
  // Assemble all input
  let data = if self.input_chunks.length() == 0 {
    Bytes::default()
  } else if self.input_chunks.length() == 1 {
    self.input_chunks[0]
  } else {
    let result = FixedArray::make(self.total_input, b'\x00')
    let mut offset = 0
    for chunk in self.input_chunks {
      for i in 0..<chunk.length() {
        result[offset + i] = chunk[i]
      }
      offset += chunk.length()
    }
    result.unsafe_reinterpret_as_bytes()
  }
  // Compress using one-shot L1 approach
  let output = if lvl == 0 {
    deflate_stored(data)
  } else {
    deflate_lz77(data, lvl)
  }
  self.phase = Finished
  self.input_chunks.clear()
  self.total_input = 0
  if output.length() > 0 {
    self.pending_output = Bytes::default()
    Data(output)
  } else {
    End
  }
}

///|
fn deflate_stored(data : Bytes) -> Bytes {
  let buf = @buffer.new(size_hint=data.length() + 11)
  let mut offset = 0
  while offset < data.length() || offset == 0 {
    let remaining = data.length() - offset
    let block_len = if remaining > 65535 { 65535 } else { remaining }
    let is_final = offset + block_len >= data.length()
    buf.write_byte(if is_final { b'\x01' } else { b'\x00' })
    buf.write_byte((block_len & 0xFF).to_byte())
    buf.write_byte((block_len >> 8).to_byte())
    let nlen = block_len ^ 0xFFFF
    buf.write_byte((nlen & 0xFF).to_byte())
    buf.write_byte((nlen >> 8).to_byte())
    buf.write_bytesview(data[offset:offset + block_len])
    offset += block_len
    if data.length() == 0 {
      break
    }
  }
  buf.to_bytes()
}

///|
fn deflate_lz77(data : Bytes, level : Int) -> Bytes {
  let w = BitWriter::new(size_hint=data.length())
  if data.length() == 0 {
    w.start_fixed_block(true)
    w.write_fixed_symbol(END_BLOCK_MARKER)
    return w.finish()
  }
  if level <= 1 {
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
fn deflate_fast_direct(data : Bytes, w : BitWriter) -> Bytes {
  let data_len = data.length()
  let hash_size = 1 << 15
  let hash_mask = hash_size - 1
  let head = FixedArray::make(hash_size, -1)
  w.start_fixed_block(true)
  let mut i = 0
  while i < data_len {
    if i + 3 < data_len {
      let v = data.unsafe_read_uint32_le(i).reinterpret_as_int()
      let h = ((v & 0xFFFFFF) ^ (((v >> 16) & 0xFF) * 0x1e35a7bd)) & hash_mask
      let match_pos = head[h]
      head[h] = i
      if match_pos >= 0 && i - match_pos <= MAX_MATCH_OFFSET {
        let max_len = if data_len - i < MAX_MATCH_LENGTH {
          data_len - i
        } else {
          MAX_MATCH_LENGTH
        }
        let length = match_len(data, i, match_pos, max_len)
        if length >= MIN_MATCH_LENGTH {
          w.write_match_fast(length, i - match_pos)
          if i + 4 < data_len {
            let v1 = data.unsafe_read_uint32_le(i + 1).reinterpret_as_int()
            let h1 = ((v1 & 0xFFFFFF) ^ (((v1 >> 16) & 0xFF) * 0x1e35a7bd)) &
              hash_mask
            head[h1] = i + 1
          }
          i += length
          continue
        }
      }
    }
    w.write_literal_fast(data.unsafe_get(i))
    i += 1
  }
  w.write_fixed_symbol(END_BLOCK_MARKER)
  w.finish()
}

///|
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
    if i + 3 < data_len {
      let v = data.unsafe_read_uint32_le(i).reinterpret_as_int()
      let h = ((v & 0xFFFFFF) ^ (((v >> 16) & 0xFF) * 0x1e35a7bd)) & hash_mask
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
            let pos = i + j
            if pos + 3 < data_len {
              let vj = data.unsafe_read_uint32_le(pos).reinterpret_as_int()
              let hj = ((vj & 0xFFFFFF) ^ (((vj >> 16) & 0xFF) * 0x1e35a7bd)) &
                hash_mask
              prev[pos & window_mask] = head[hj]
              head[hj] = pos
            }
          }
          i += length
          continue
        }
      }
    }
    tokens.push(Token::literal(data.unsafe_get(i)))
    i += 1
  }
  tokens
}

///|
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
    if i + 3 < data_len {
      let v = data.unsafe_read_uint32_le(i).reinterpret_as_int()
      let h = ((v & 0xFFFFFF) ^ (((v >> 16) & 0xFF) * 0x1e35a7bd)) & hash_mask
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
        tokens.push(Token::literal(prev_literal))
        prev_match_len = cur_len
        prev_match_dist = cur_dist
        prev_literal = data.unsafe_get(i)
        i += 1
      } else {
        tokens.push(Token::match_(prev_match_len, prev_match_dist))
        let start = i
        let end = start + prev_match_len - 1
        for j in start..<end {
          if j + 3 < data_len {
            let vj = data.unsafe_read_uint32_le(j).reinterpret_as_int()
            let hj = ((vj & 0xFFFFFF) ^ (((vj >> 16) & 0xFF) * 0x1e35a7bd)) &
              hash_mask
            prev[j & window_mask] = head[hj]
            head[hj] = j
          }
        }
        i = end
        has_prev = false
      }
    } else if cur_len >= MIN_MATCH_LENGTH {
      has_prev = true
      prev_match_len = cur_len
      prev_match_dist = cur_dist
      prev_literal = data.unsafe_get(i)
      i += 1
    } else {
      tokens.push(Token::literal(data.unsafe_get(i)))
      i += 1
    }
  }
  if has_prev {
    tokens.push(Token::match_(prev_match_len, prev_match_dist))
  }
  tokens
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
    if best_len > 0 &&
      data.unsafe_get(pos + best_len) != data.unsafe_get(cur + best_len) {
      let next = prev[pos & window_mask]
      if next >= pos {
        break
      }
      pos = next
      chain_count += 1
      continue
    }
    let length = match_len(data, cur, pos, max_len)
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
