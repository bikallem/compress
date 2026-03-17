///|
/// Phase of the deflate state machine.
priv enum DeflatePhase {
  Ready
  Finished
  Failed(CompressError)
}

///|
/// 4-byte hash for the hash chain, masked to hash_mask.
/// SAFETY: caller must ensure pos+3 < window.length().
fn Deflater::hash4(self : Deflater, pos : Int, hash_mask : Int) -> Int {
  let w = self.window
  let v = w.unsafe_get(pos).to_int() |
    (w.unsafe_get(pos + 1).to_int() << 8) |
    (w.unsafe_get(pos + 2).to_int() << 16) |
    (w.unsafe_get(pos + 3).to_int() << 24)
  ((v & 0xFFFFFF) ^ (((v >> 16) & 0xFF) * 0x1e35a7bd)) & hash_mask
}

///|
/// Insert position into hash chain and return previous head.
/// SAFETY: caller must ensure pos+3 < window.length().
fn Deflater::insert_hash(self : Deflater, pos : Int, hash_mask : Int) -> Int {
  let h = self.hash4(pos, hash_mask)
  let match_head = self.head.unsafe_get(h)
  self.prev.unsafe_set(pos & WINDOW_MASK, match_head)
  self.head.unsafe_set(h, pos)
  match_head
}

///|
/// Check if 4 bytes match at positions a and b in the window.
/// SAFETY: caller must ensure a+3 and b+3 are within window bounds.
fn Deflater::match4(self : Deflater, a : Int, b : Int) -> Bool {
  let w = self.window
  w.unsafe_get(a) == w.unsafe_get(b) &&
  w.unsafe_get(a + 1) == w.unsafe_get(b + 1) &&
  w.unsafe_get(a + 2) == w.unsafe_get(b + 2) &&
  w.unsafe_get(a + 3) == w.unsafe_get(b + 3)
}

///|
/// Collect literal tokens for window[from..<to] and flush if block is full.
fn Deflater::emit_literals(self : Deflater, from : Int, to : Int) -> Unit {
  let window = self.window
  for j in from..<to {
    self.tokens.push(Token::literal(window.unsafe_get(j)))
    if self.tokens.length() >= MAX_BLOCK_TOKENS {
      self.w.write_dynamic_block(self.tokens, false)
      self.tokens.clear()
    }
  }
}

///|
/// Flush token buffer as a dynamic block if it has reached the block size limit.
fn Deflater::maybe_flush_tokens(self : Deflater) -> Unit {
  if self.tokens.length() >= MAX_BLOCK_TOKENS {
    self.w.write_dynamic_block(self.tokens, false)
    self.tokens.clear()
  }
}

///|
const WINDOW_SIZE : Int = 1 << 15 // 32KB

///|
const WINDOW_MASK : Int = WINDOW_SIZE - 1

///|
const MAX_BLOCK_TOKENS : Int = 16384

///|
/// Maximum number of intermediate positions to rehash after a match.
/// At low levels, capped at 32 for speed (hash4 + insert_hash dominates
/// CPU cost). At higher levels, rehash all positions for better ratio.
fn max_insert(level : Int) -> Int {
  if level <= 3 {
    32
  } else {
    MAX_MATCH_LENGTH
  }
}

///|
/// Streaming, non-blocking DEFLATE compressor.
///
/// Memory: ~450KB constant regardless of input size (double window + hash tables).
///
/// The caller drives the encode loop:
///   - `encode(Some(data))` feeds input, may return `Data(bytes)` or `Ok`
///   - `encode(None)` signals EOF, may return `Data(bytes)` or `End`
struct Deflater {
  level : Int
  w : BitWriter
  mut phase : DeflatePhase
  // Sliding window (double-sized for lookback)
  window : FixedArray[Byte]
  mut window_end : Int
  mut index : Int
  // Hash tables
  head : FixedArray[Int]
  prev : FixedArray[Int]
  // Token buffer
  tokens : Array[Token]
  // Lazy match state (levels 4+)
  mut prev_match_len : Int
  mut prev_match_dist : Int
  mut prev_literal : Byte
  mut has_prev : Bool
}

///|
pub fn Deflater::new(
  level? : CompressionLevel = DefaultCompression,
  dict? : Bytes,
) -> Deflater {
  let lvl = level.to_int()
  let hash_size = 1 << 15
  let window = FixedArray::make(2 * WINDOW_SIZE, b'\x00')
  let head = FixedArray::make(hash_size, -1)
  let prev_arr = FixedArray::make(WINDOW_SIZE, -1)
  let d = {
    level: lvl,
    w: BitWriter::new(),
    phase: Ready,
    window,
    window_end: 0,
    index: 0,
    head,
    prev: prev_arr,
    tokens: [],
    prev_match_len: 0,
    prev_match_dist: 0,
    prev_literal: b'\x00',
    has_prev: false,
  }
  // Preload dictionary if provided
  match dict {
    Some(dict_bytes) =>
      if dict_bytes.length() > 0 && lvl != 0 {
        let dict_len = if dict_bytes.length() > WINDOW_SIZE {
          WINDOW_SIZE
        } else {
          dict_bytes.length()
        }
        let dict_start = dict_bytes.length() - dict_len
        for i in 0..<dict_len {
          d.window[i] = dict_bytes[dict_start + i]
        }
        d.window_end = dict_len
        d.index = dict_len
        if lvl >= 1 {
          let hash_mask = d.head.length() - 1
          for i in 0..<(dict_len - 3) {
            ignore(d.insert_hash(i, hash_mask))
          }
        }
      }
    None => ()
  }
  d
}

///|
/// Single entry point for encoding.
///   encode(Some(data)) — feed input to compress
///   encode(None)       — signal end of input, flush final block
pub fn Deflater::encode(self : Deflater, data : BytesView?) -> Encode {
  match self.phase {
    Failed(e) => Error(e)
    Finished => End
    Ready => {
      let lvl = self.level
      if lvl < -2 || lvl > 9 {
        self.phase = Failed(CompressError::InvalidLevel(lvl))
        return Error(CompressError::InvalidLevel(lvl))
      }
      match data {
        Some(chunk) => self.feed(chunk)
        None => self.do_finish()
      }
    }
  }
}

///|
/// Feed input bytes into the window, process, return accumulated output.
fn Deflater::feed(self : Deflater, data : BytesView) -> Encode {
  if data.length() == 0 {
    return Ok
  }
  let shift_trigger = 2 * WINDOW_SIZE - (MIN_MATCH_LENGTH + MAX_MATCH_LENGTH)
  let mut offset = 0
  while offset < data.length() {
    if self.index >= shift_trigger {
      self.shift_window()
    }
    let space = self.window.length() - self.window_end
    let n = if data.length() - offset < space {
      data.length() - offset
    } else {
      space
    }
    @blit.blit_bytesview(self.window, self.window_end, data, offset, n)
    self.window_end += n
    offset += n
    self.step()
  }
  let output = self.w.take_output()
  if output.length() > 0 {
    Data(output)
  } else {
    Ok
  }
}

///|
/// Finish compression: flush remaining data and write final block.
fn Deflater::do_finish(self : Deflater) -> Encode {
  self.flush_remaining()
  // Write final empty stored block (BFINAL=1)
  self.w.write_stored_header(0, true)
  let output = self.w.finish()
  self.phase = Finished
  if output.length() > 0 {
    Data(output)
  } else {
    End
  }
}

///|
fn Deflater::shift_window(self : Deflater) -> Unit {
  @blit.blit_fixed_array(self.window, 0, self.window, WINDOW_SIZE, WINDOW_SIZE)
  self.window_end -= WINDOW_SIZE
  self.index -= WINDOW_SIZE
  let head = self.head
  for i, h in head {
    let v = h - WINDOW_SIZE
    head.unsafe_set(i, if v < 0 { -1 } else { v })
  }
  let prev = self.prev
  for i, p in prev {
    let v = p - WINDOW_SIZE
    prev.unsafe_set(i, if v < 0 { -1 } else { v })
  }
}

///|
fn Deflater::step(self : Deflater) -> Unit {
  match self.level {
    0 => self.step_stored()
    1 => self.step_fast()
    2 | 3 => self.step_greedy()
    _ => self.step_lazy()
  }
}

///|
fn Deflater::step_stored(self : Deflater) -> Unit {
  while self.index < self.window_end {
    let remaining = self.window_end - self.index
    let block_len = if remaining > 65535 { 65535 } else { remaining }
    self.w.write_stored_header(block_len, false)
    self.w.write_stored_data(self.window, self.index, block_len)
    self.index += block_len
  }
}

///|
/// Snappy-style fast compressor (level 1). Matches Go's deflateFast algorithm:
/// adaptive skip on miss, immediate re-probe after match for chaining.
/// Uses dynamic Huffman blocks for optimal encoding.
fn Deflater::step_fast(self : Deflater) -> Unit {
  let hash_mask = self.head.length() - 1
  let head = self.head
  let end = self.window_end
  let mut i = self.index
  let safe_end = end - MIN_MATCH_LENGTH
  if i >= safe_end {
    self.index = i
    return
  }
  let mut next_emit = i // start of pending literal run
  // Outer loop: find matches via adaptive skip, then chain
  while i < safe_end {
    // --- Skip loop: find a 4-byte match with adaptive skipping ---
    // After 32 bytes without a match, start skipping bytes (like Snappy).
    let mut skip = 32
    let mut candidate = -1
    let mut found = false
    while true {
      let step = skip >> 5
      let next_i = i + step
      skip += step
      if next_i > safe_end {
        break
      }
      let h = self.hash4(i, hash_mask)
      candidate = head.unsafe_get(h)
      head.unsafe_set(h, i)
      if candidate >= 0 &&
        i - candidate <= MAX_MATCH_OFFSET &&
        self.match4(i, candidate) {
        found = true
        break
      }
      i = next_i
    }
    if not(found) {
      break // no more matches possible
    }
    self.emit_literals(next_emit, i)
    // --- Match loop: extend match, emit, then try to chain ---
    while true {
      let max_len = if end - i < MAX_MATCH_LENGTH {
        end - i
      } else {
        MAX_MATCH_LENGTH
      }
      let length = self.match_len(i, candidate, max_len)
      self.tokens.push(Token::match_(length, i - candidate))
      i += length
      next_emit = i
      self.maybe_flush_tokens()
      if i >= safe_end {
        break
      }
      // Hash i-1, then hash i and check for a chained match.
      // i-1 is always valid (length >= MIN_MATCH_LENGTH = 3).
      head.unsafe_set(self.hash4(i - 1, hash_mask), i - 1)
      let h = self.hash4(i, hash_mask)
      candidate = head.unsafe_get(h)
      head.unsafe_set(h, i)
      if candidate >= 0 &&
        i - candidate <= MAX_MATCH_OFFSET &&
        self.match4(i, candidate) {
        continue // chain: another match starts here
      }
      // No chain, advance past current position and resume skip loop
      i += 1
      break
    }
  }
  self.emit_literals(next_emit, end)
  self.index = end
}

///|
fn Deflater::step_greedy(self : Deflater) -> Unit {
  let hash_mask = self.head.length() - 1
  let max_chain = if self.level == 2 { 8 } else { 16 }
  let max_ins = max_insert(self.level)
  let end = self.window_end
  let mut i = self.index
  let safe_end = end - MIN_MATCH_LENGTH
  if i >= safe_end {
    self.index = i
    return
  }
  while i < safe_end {
    // i < safe_end guarantees i+3 < end
    let match_head = self.insert_hash(i, hash_mask)
    if match_head >= 0 && i - match_head <= MAX_MATCH_OFFSET {
      let (length, offset) = self.find_best_match(i, match_head, max_chain)
      if length >= MIN_MATCH_LENGTH {
        self.tokens.push(Token::match_(length, offset))
        // Rehash intermediate positions (capped at low levels for speed).
        let n_insert = if length - 1 < max_ins { length - 1 } else { max_ins }
        let rehash_end = if i + n_insert + 4 < end {
          i + 1 + n_insert
        } else {
          end - 3
        }
        for pos in (i + 1)..<rehash_end {
          ignore(self.insert_hash(pos, hash_mask))
        }
        i += length
        self.maybe_flush_tokens()
        continue
      }
    }
    self.tokens.push(Token::literal(self.window.unsafe_get(i)))
    i += 1
    self.maybe_flush_tokens()
  }
  self.index = i
}

///|
fn Deflater::step_lazy(self : Deflater) -> Unit {
  let hash_mask = self.head.length() - 1
  let max_chain = match self.level {
    4 => 32
    5 => 64
    6 => 128
    7 => 256
    8 => 512
    _ => 1024
  }
  let max_ins = max_insert(self.level)
  let end = self.window_end
  let mut i = self.index
  let safe_end = end - MIN_MATCH_LENGTH
  if i >= safe_end {
    self.index = i
    return
  }
  while i < safe_end {
    // i < safe_end guarantees i+3 < end
    let mut cur_len = 0
    let mut cur_dist = 0
    let match_head = self.insert_hash(i, hash_mask)
    if match_head >= 0 && i - match_head <= MAX_MATCH_OFFSET {
      let (length, offset) = self.find_best_match(i, match_head, max_chain)
      if length >= MIN_MATCH_LENGTH {
        cur_len = length
        cur_dist = offset
      }
    }
    if self.has_prev {
      if cur_len > self.prev_match_len + 1 {
        self.tokens.push(Token::literal(self.prev_literal))
        self.prev_match_len = cur_len
        self.prev_match_dist = cur_dist
        self.prev_literal = self.window.unsafe_get(i)
        i += 1
      } else {
        self.tokens.push(
          Token::match_(self.prev_match_len, self.prev_match_dist),
        )
        let start = i
        let skip_end = start + self.prev_match_len - 1
        // Rehash intermediate positions (capped at low levels for speed).
        let n_insert = if self.prev_match_len - 1 < max_ins {
          self.prev_match_len - 1
        } else {
          max_ins
        }
        let rehash_end = if start + n_insert + 3 < end {
          start + n_insert
        } else {
          end - 4
        }
        for j in start..<rehash_end {
          ignore(self.insert_hash(j, hash_mask))
        }
        i = skip_end
        self.has_prev = false
      }
    } else if cur_len >= MIN_MATCH_LENGTH {
      self.has_prev = true
      self.prev_match_len = cur_len
      self.prev_match_dist = cur_dist
      self.prev_literal = self.window.unsafe_get(i)
      i += 1
    } else {
      self.tokens.push(Token::literal(self.window.unsafe_get(i)))
      i += 1
    }
    self.maybe_flush_tokens()
  }
  self.index = i
}

///|
fn Deflater::flush_tokens(self : Deflater) -> Unit {
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
fn Deflater::flush_remaining(self : Deflater) -> Unit {
  if self.level == 0 {
    let remaining = self.window_end - self.index
    if remaining > 0 {
      self.w.write_stored_header(remaining, false)
      self.w.write_stored_data(self.window, self.index, remaining)
      self.index = self.window_end
    }
    return
  }
  // Emit pending lazy match before remaining literals.
  // When step_lazy exits with has_prev=true, self.index is match_start+1.
  // The match covers match_start through match_start+prev_match_len-1,
  // so we must advance index past the match to avoid double-emitting bytes.
  if self.has_prev {
    self.tokens.push(Token::match_(self.prev_match_len, self.prev_match_dist))
    self.index += self.prev_match_len - 1
    self.has_prev = false
  }
  if self.index < self.window_end {
    match self.level {
      0 | 1 => {
        self.w.start_fixed_block(false)
        while self.index < self.window_end {
          self.w.write_literal_fast(self.window[self.index])
          self.index += 1
        }
        self.w.write_fixed_symbol(END_BLOCK_MARKER)
      }
      _ =>
        while self.index < self.window_end {
          self.tokens.push(Token::literal(self.window[self.index]))
          self.index += 1
        }
    }
  }
  self.flush_tokens()
}

///|
fn Deflater::match_len(self : Deflater, a : Int, b : Int, max_len : Int) -> Int {
  @blit.match_length(self.window, a, self.window, b, max_len)
}

///|
/// SAFETY: cur and match_head are valid window positions (caller guarantees
/// cur+3 < window_end and match_head comes from the hash table).
fn Deflater::find_best_match(
  self : Deflater,
  cur : Int,
  match_head : Int,
  max_chain : Int,
) -> (Int, Int) {
  let window = self.window
  let prev = self.prev
  let mut best_len = MIN_MATCH_LENGTH - 1
  let mut best_offset = 0
  let mut pos = match_head
  let mut chain_count = 0
  let max_len = if self.window_end - cur < MAX_MATCH_LENGTH {
    self.window_end - cur
  } else {
    MAX_MATCH_LENGTH
  }
  while pos >= 0 && cur - pos <= MAX_MATCH_OFFSET && chain_count < max_chain {
    // Early exit: check the byte at best_len position first to skip
    // non-matching chain entries without calling match_len.
    if best_len > 0 &&
      window.unsafe_get(pos + best_len) != window.unsafe_get(cur + best_len) {
      let next = prev.unsafe_get(pos & WINDOW_MASK)
      if next >= pos {
        break
      }
      pos = next
      chain_count += 1
      continue
    }
    let length = self.match_len(cur, pos, max_len)
    if length > best_len {
      best_len = length
      best_offset = cur - pos
      if best_len == max_len {
        break
      }
    }
    let next = prev.unsafe_get(pos & WINDOW_MASK)
    if next >= pos {
      break
    }
    pos = next
    chain_count += 1
  }
  (best_len, best_offset)
}
