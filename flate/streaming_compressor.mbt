///|
const WINDOW_SIZE : Int = 1 << 15 // 32KB

///|
const WINDOW_MASK : Int = WINDOW_SIZE - 1

///|
const MAX_BLOCK_TOKENS : Int = 16384

///|
/// Streaming DEFLATE compressor. Processes input incrementally using a
/// sliding window, emitting compressed blocks to a @stream.Writer.
/// Memory: ~450KB constant regardless of input size.
priv struct StreamingCompressor {
  w : StreamingBitWriter
  level : Int
  // Double-sized window for lookback
  window : FixedArray[Byte]
  mut window_end : Int
  mut index : Int // next unprocessed position
  mut block_start : Int // start of current block's data
  // Hash tables
  head : FixedArray[Int]
  prev : FixedArray[Int]
  mut hash_offset : Int // virtual address offset for window shifts
  // Tokens
  tokens : Array[Token]
  // Lazy match state (levels 4+)
  mut prev_match_len : Int
  mut prev_match_dist : Int
  mut prev_literal : Byte
  mut has_prev : Bool
}

///|
fn StreamingCompressor::new(
  dest : &@stream.Writer,
  level : Int,
) -> StreamingCompressor {
  let hash_size = 1 << 15
  {
    w: StreamingBitWriter::new(dest),
    level,
    window: FixedArray::make(2 * WINDOW_SIZE, b'\x00'),
    window_end: 0,
    index: 0,
    block_start: 0,
    head: FixedArray::make(hash_size, -1),
    prev: FixedArray::make(WINDOW_SIZE, -1),
    hash_offset: 0,
    tokens: [],
    prev_match_len: 0,
    prev_match_dist: 0,
    prev_literal: b'\x00',
    has_prev: false,
  }
}

///|
/// Fill window with input data. Returns number of bytes consumed.
fn StreamingCompressor::fill(
  self : StreamingCompressor,
  data : BytesView,
) -> Int {
  // Shift window if needed: when index is past the safe zone
  let shift_trigger = 2 * WINDOW_SIZE - (MIN_MATCH_LENGTH + MAX_MATCH_LENGTH)
  if self.index >= shift_trigger {
    self.shift_window()
  }
  let space = self.window.length() - self.window_end
  let n = if data.length() < space { data.length() } else { space }
  for i in 0..<n {
    self.window[self.window_end + i] = data[i]
  }
  self.window_end += n
  n
}

///|
/// Shift window: move second half to first half, adjust hash tables.
fn StreamingCompressor::shift_window(self : StreamingCompressor) -> Unit {
  // Copy second half to first half
  @blit.blit_bytes(self.window, 0, self.window, WINDOW_SIZE, WINDOW_SIZE)
  self.window_end -= WINDOW_SIZE
  self.index -= WINDOW_SIZE
  self.block_start -= WINDOW_SIZE
  self.hash_offset += WINDOW_SIZE
  // Adjust hash tables: decrement by WINDOW_SIZE, invalidate if negative
  let head = self.head
  for i in 0..<head.length() {
    let v = head[i] - WINDOW_SIZE
    head[i] = if v < 0 { -1 } else { v }
  }
  let prev = self.prev
  for i in 0..<prev.length() {
    let v = prev[i] - WINDOW_SIZE
    prev[i] = if v < 0 { -1 } else { v }
  }
}

///|
/// Process data in window, emit blocks as needed.
fn StreamingCompressor::step(
  self : StreamingCompressor,
) -> Unit raise @stream.StreamError {
  if self.level == 0 {
    self.step_stored()
    return
  }
  if self.level <= 1 {
    self.step_fast()
    return
  }
  if self.level <= 3 {
    self.step_greedy()
    return
  }
  self.step_lazy()
}

///|
/// Stored blocks: no compression, just chunk into 65535-byte blocks.
fn StreamingCompressor::step_stored(
  self : StreamingCompressor,
) -> Unit raise @stream.StreamError {
  while self.index < self.window_end {
    let remaining = self.window_end - self.index
    let block_len = if remaining > 65535 { 65535 } else { remaining }
    // Non-final block (finish() writes the final one)
    self.w.write_stored_header(block_len, false)
    self.w.write_stored_data(self.window, self.index, block_len)
    self.index += block_len
    self.block_start = self.index
  }
}

///|
/// Level 1 fast: single hash, fixed Huffman, emit directly.
fn StreamingCompressor::step_fast(
  self : StreamingCompressor,
) -> Unit raise @stream.StreamError {
  let window = self.window
  let head = self.head
  let hash_mask = head.length() - 1
  let end = self.window_end
  let mut i = self.index
  // Need at least MIN_MATCH_LENGTH + MAX_MATCH_LENGTH bytes of lookahead
  // to avoid needing to handle edge cases at the boundary
  let safe_end = end - MIN_MATCH_LENGTH
  if i >= safe_end {
    self.index = i
    return
  }
  // Start a fixed block
  self.w.start_fixed_block(false)
  while i < safe_end {
    if i + 3 < end {
      let b0 = window[i].to_int()
      let b1 = window[i + 1].to_int()
      let b2 = window[i + 2].to_int()
      let b3 = window[i + 3].to_int()
      let v = b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
      let h = ((v & 0xFFFFFF) ^ (((v >> 16) & 0xFF) * 0x1e35a7bd)) & hash_mask
      let match_pos = head[h]
      head[h] = i
      if match_pos >= 0 && i - match_pos <= MAX_MATCH_OFFSET {
        let max_len = if end - i < MAX_MATCH_LENGTH {
          end - i
        } else {
          MAX_MATCH_LENGTH
        }
        let length = match_len_window(window, i, match_pos, max_len)
        if length >= MIN_MATCH_LENGTH {
          self.w.write_match_fast(length, i - match_pos)
          // Hash next position
          if i + 4 < end {
            let nb0 = window[i + 1].to_int()
            let nb1 = window[i + 2].to_int()
            let nb2 = window[i + 3].to_int()
            let nb3 = window[i + 4].to_int()
            let nv = nb0 | (nb1 << 8) | (nb2 << 16) | (nb3 << 24)
            let nh = ((nv & 0xFFFFFF) ^ (((nv >> 16) & 0xFF) * 0x1e35a7bd)) &
              hash_mask
            head[nh] = i + 1
          }
          i += length
          continue
        }
      }
    }
    self.w.write_literal_fast(window[i])
    i += 1
  }
  self.w.write_fixed_symbol(END_BLOCK_MARKER)
  self.index = i
  self.block_start = i
}

///|
/// Levels 2-3: greedy with hash chains, collect tokens, emit blocks.
fn StreamingCompressor::step_greedy(
  self : StreamingCompressor,
) -> Unit raise @stream.StreamError {
  let window = self.window
  let head = self.head
  let prev = self.prev
  let hash_mask = head.length() - 1
  let max_chain = if self.level == 2 { 8 } else { 16 }
  let end = self.window_end
  let mut i = self.index
  let safe_end = end - MIN_MATCH_LENGTH
  if i >= safe_end {
    self.index = i
    return
  }
  while i < safe_end {
    if i + 3 < end {
      let b0 = window[i].to_int()
      let b1 = window[i + 1].to_int()
      let b2 = window[i + 2].to_int()
      let b3 = window[i + 3].to_int()
      let v = b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
      let h = ((v & 0xFFFFFF) ^ (((v >> 16) & 0xFF) * 0x1e35a7bd)) & hash_mask
      let match_head = head[h]
      prev[i & WINDOW_MASK] = match_head
      head[h] = i
      if match_head >= 0 && i - match_head <= MAX_MATCH_OFFSET {
        let (length, offset) = find_best_match_window(
          window, end, i, match_head, prev, max_chain,
        )
        if length >= MIN_MATCH_LENGTH {
          self.tokens.push(Token::match_(length, offset))
          // Update hash chains for skipped bytes
          for j in 1..<length {
            let pos = i + j
            if pos + 3 < end {
              let jb0 = window[pos].to_int()
              let jb1 = window[pos + 1].to_int()
              let jb2 = window[pos + 2].to_int()
              let jb3 = window[pos + 3].to_int()
              let jv = jb0 | (jb1 << 8) | (jb2 << 16) | (jb3 << 24)
              let jh = ((jv & 0xFFFFFF) ^ (((jv >> 16) & 0xFF) * 0x1e35a7bd)) &
                hash_mask
              prev[pos & WINDOW_MASK] = head[jh]
              head[jh] = pos
            }
          }
          i += length
          if self.tokens.length() >= MAX_BLOCK_TOKENS {
            self.w.write_dynamic_block(self.tokens, false)
            self.tokens.clear()
          }
          continue
        }
      }
    }
    self.tokens.push(Token::literal(window[i]))
    i += 1
    if self.tokens.length() >= MAX_BLOCK_TOKENS {
      self.w.write_dynamic_block(self.tokens, false)
      self.tokens.clear()
    }
  }
  self.index = i
  self.block_start = i
}

///|
/// Levels 4-9: lazy matching with hash chains.
fn StreamingCompressor::step_lazy(
  self : StreamingCompressor,
) -> Unit raise @stream.StreamError {
  let window = self.window
  let head = self.head
  let prev = self.prev
  let hash_mask = head.length() - 1
  let max_chain = match self.level {
    4 => 32
    5 => 64
    6 => 128
    7 => 256
    8 => 512
    _ => 1024
  }
  let end = self.window_end
  let mut i = self.index
  let safe_end = end - MIN_MATCH_LENGTH
  if i >= safe_end {
    self.index = i
    return
  }
  while i < safe_end {
    let mut cur_len = 0
    let mut cur_dist = 0
    if i + 3 < end {
      let b0 = window[i].to_int()
      let b1 = window[i + 1].to_int()
      let b2 = window[i + 2].to_int()
      let b3 = window[i + 3].to_int()
      let v = b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
      let h = ((v & 0xFFFFFF) ^ (((v >> 16) & 0xFF) * 0x1e35a7bd)) & hash_mask
      let match_head = head[h]
      prev[i & WINDOW_MASK] = match_head
      head[h] = i
      if match_head >= 0 && i - match_head <= MAX_MATCH_OFFSET {
        let (length, offset) = find_best_match_window(
          window, end, i, match_head, prev, max_chain,
        )
        if length >= MIN_MATCH_LENGTH {
          cur_len = length
          cur_dist = offset
        }
      }
    }
    if self.has_prev {
      if cur_len > self.prev_match_len + 1 {
        // Current match better — emit previous as literal
        self.tokens.push(Token::literal(self.prev_literal))
        self.prev_match_len = cur_len
        self.prev_match_dist = cur_dist
        self.prev_literal = window[i]
        i += 1
      } else {
        // Previous match wins — emit it
        self.tokens.push(
          Token::match_(self.prev_match_len, self.prev_match_dist),
        )
        let start = i
        let skip_end = start + self.prev_match_len - 1
        for j in start..<skip_end {
          if j + 3 < end {
            let jb0 = window[j].to_int()
            let jb1 = window[j + 1].to_int()
            let jb2 = window[j + 2].to_int()
            let jb3 = window[j + 3].to_int()
            let jv = jb0 | (jb1 << 8) | (jb2 << 16) | (jb3 << 24)
            let jh = ((jv & 0xFFFFFF) ^ (((jv >> 16) & 0xFF) * 0x1e35a7bd)) &
              hash_mask
            prev[j & WINDOW_MASK] = head[jh]
            head[jh] = j
          }
        }
        i = skip_end
        self.has_prev = false
      }
    } else if cur_len >= MIN_MATCH_LENGTH {
      // Defer: try next position
      self.has_prev = true
      self.prev_match_len = cur_len
      self.prev_match_dist = cur_dist
      self.prev_literal = window[i]
      i += 1
    } else {
      self.tokens.push(Token::literal(window[i]))
      i += 1
    }
    if self.tokens.length() >= MAX_BLOCK_TOKENS {
      self.w.write_dynamic_block(self.tokens, false)
      self.tokens.clear()
    }
  }
  self.index = i
  self.block_start = i
}

///|
/// Flush any remaining tokens as a non-final block.
fn StreamingCompressor::flush_tokens(
  self : StreamingCompressor,
) -> Unit raise @stream.StreamError {
  if self.has_prev {
    self.tokens.push(Token::match_(self.prev_match_len, self.prev_match_dist))
    self.has_prev = false
  }
  if self.tokens.length() > 0 {
    self.w.write_dynamic_block(self.tokens, false)
    self.tokens.clear()
  }
}

///|
/// Process any remaining bytes at the end of input that were
/// below the safe_end threshold during step().
fn StreamingCompressor::flush_remaining(
  self : StreamingCompressor,
) -> Unit raise @stream.StreamError {
  if self.level == 0 {
    // Any remaining stored data
    let remaining = self.window_end - self.index
    if remaining > 0 {
      self.w.write_stored_header(remaining, false)
      self.w.write_stored_data(self.window, self.index, remaining)
      self.index = self.window_end
    }
    return
  }
  // Emit remaining bytes as literals (too few for matching)
  let window = self.window
  while self.index < self.window_end {
    if self.level <= 1 {
      // For fast mode, we need to open/close a fixed block
      self.w.start_fixed_block(false)
      while self.index < self.window_end {
        self.w.write_literal_fast(window[self.index])
        self.index += 1
      }
      self.w.write_fixed_symbol(END_BLOCK_MARKER)
    } else {
      self.tokens.push(Token::literal(window[self.index]))
      self.index += 1
    }
  }
  self.flush_tokens()
}

///|
/// Finish compression: flush all remaining data and write final empty block.
fn StreamingCompressor::finish(
  self : StreamingCompressor,
) -> Unit raise @stream.StreamError {
  self.flush_remaining()
  // Write final empty stored block (BFINAL=1)
  self.w.write_stored_header(0, true)
  self.w.finish()
}

///|
/// Match length comparison on FixedArray[Byte] (window).
fn match_len_window(
  data : FixedArray[Byte],
  a : Int,
  b : Int,
  max_len : Int,
) -> Int {
  let mut len = 0
  while len < max_len && data[a + len] == data[b + len] {
    len += 1
  }
  len
}

///|
/// Find best match in hash chain for window-based compression.
fn find_best_match_window(
  window : FixedArray[Byte],
  window_end : Int,
  cur : Int,
  match_head : Int,
  prev : FixedArray[Int],
  max_chain : Int,
) -> (Int, Int) {
  let mut best_len = MIN_MATCH_LENGTH - 1
  let mut best_offset = 0
  let mut pos = match_head
  let mut chain_count = 0
  let max_len = if window_end - cur < MAX_MATCH_LENGTH {
    window_end - cur
  } else {
    MAX_MATCH_LENGTH
  }
  while pos >= 0 && cur - pos <= MAX_MATCH_OFFSET && chain_count < max_chain {
    if best_len > 0 && window[pos + best_len] != window[cur + best_len] {
      let next = prev[pos & WINDOW_MASK]
      if next >= pos {
        break
      }
      pos = next
      chain_count += 1
      continue
    }
    let length = match_len_window(window, cur, pos, max_len)
    if length > best_len {
      best_len = length
      best_offset = cur - pos
      if best_len == max_len {
        break
      }
    }
    let next = prev[pos & WINDOW_MASK]
    if next >= pos {
      break
    }
    pos = next
    chain_count += 1
  }
  (best_len, best_offset)
}
