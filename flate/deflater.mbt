///|
/// Phase of the deflate state machine.
priv enum DeflatePhase {
  Ready
  Finished
  Failed(CompressError)
}

///|
/// 4-byte multiplicative hash for the hash chain, masked to hash_mask.
/// Uses all 4 bytes for fewer collisions than the old 3-byte hash.
/// SAFETY: caller must ensure pos+3 < window.length().
fn Deflater::hash4(self : Deflater, pos : Int, hash_mask : Int) -> Int {
  let w = self.window
  let v = w.unsafe_get(pos).to_int() |
    (w.unsafe_get(pos + 1).to_int() << 8) |
    (w.unsafe_get(pos + 2).to_int() << 16) |
    (w.unsafe_get(pos + 3).to_int() << 24)
  ((v.reinterpret_as_uint() * 0x1e35a7bdU).reinterpret_as_int() >> 17) & hash_mask
}

///|
/// Insert position into hash chain and return previous head.
/// SAFETY: caller must ensure pos+3 < window.length().
fn Deflater::insert_hash(self : Deflater, pos : Int, hash_mask : Int) -> Int {
  let h = self.hash4(pos, hash_mask)
  let abs_pos = pos + self.base
  let match_head = self.head.unsafe_get(h)
  self.prev.unsafe_set(pos & WINDOW_MASK, match_head)
  self.head.unsafe_set(h, abs_pos)
  // Return window-relative position, or -1 if stale
  if match_head >= self.base {
    match_head - self.base
  } else {
    -1
  }
}

///|
const WINDOW_SIZE : Int = 1 << 15 // 32KB

///|
const WINDOW_MASK : Int = WINDOW_SIZE - 1

///|
const MAX_BLOCK_TOKENS : Int = 32768

///|
/// Level-dependent maximum number of intermediate positions to rehash after
/// a match. Lower levels use smaller values since their short hash chains
/// don't benefit from rehashing distant positions.
fn max_insert(level : Int) -> Int {
  match level {
    0 | 1 => 4
    2 | 3 => 32
    4 | 5 => 64
    6 | 7 => 128
    8 | 9 => 258
    _ => 258
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
  // Hash tables — positions are absolute (never shifted)
  head : FixedArray[Int]
  prev : FixedArray[Int]
  // Generation base: entries < base are stale
  mut base : Int
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
    base: 0,
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
          d.window.unsafe_set(i, dict_bytes.unsafe_get(dict_start + i))
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
  // Bump base instead of adjusting head/prev arrays.
  // Entries < base are treated as stale (-1 equivalent).
  self.base += WINDOW_SIZE
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
fn Deflater::step_fast(self : Deflater) -> Unit {
  let hash_mask = self.head.length() - 1
  let end = self.window_end
  let mut i = self.index
  let safe_end = end - MIN_MATCH_LENGTH
  if i >= safe_end {
    self.index = i
    return
  }
  // Quick check: if first 32 bytes are all the same, use uniform encoder
  if self.encode_uniform_run() {
    return
  }
  let head = self.head
  let base = self.base
  while i < safe_end {
    // i < safe_end guarantees i+3 < end, safe for hash4/unsafe_get
    let h = self.hash4(i, hash_mask)
    let match_abs = head.unsafe_get(h)
    head.unsafe_set(h, i + base)
    let match_pos = match_abs - base
    if match_abs >= base && i - match_pos <= MAX_MATCH_OFFSET {
      let max_len = if end - i < MAX_MATCH_LENGTH {
        end - i
      } else {
        MAX_MATCH_LENGTH
      }
      let length = self.match_len(i, match_pos, max_len)
      if length >= MIN_MATCH_LENGTH {
        self.tokens.push(Token::match_(length, i - match_pos))
        // After a match, hash positions at the end of the match
        // so future lookups can find overlapping matches.
        let match_end = i + length
        if match_end - 2 > i && match_end + 2 < end {
          for j in (match_end - 3)..<match_end {
            head.unsafe_set(self.hash4(j, hash_mask), j + base)
          }
        }
        i = match_end
        if self.tokens.length() >= MAX_BLOCK_TOKENS {
          self.w.write_dynamic_block(self.tokens, false)
          self.tokens.clear()
        }
        continue
      }
    }
    self.tokens.push(Token::literal(self.window.unsafe_get(i)))
    i += 1
    if self.tokens.length() >= MAX_BLOCK_TOKENS {
      self.w.write_dynamic_block(self.tokens, false)
      self.tokens.clear()
    }
  }
  self.index = i
}

///|
/// Detect and optimally encode uniform data (all same byte).
/// Returns true if data was uniform and has been encoded.
fn Deflater::encode_uniform_run(self : Deflater) -> Bool {
  let start = self.index
  let end = self.window_end
  if end - start < 32 {
    return false
  }
  let b = self.window.unsafe_get(start)
  for i in (start + 1)..<(start + 32) {
    if self.window.unsafe_get(i) != b {
      return false
    }
  }
  // Verify remaining bytes are also uniform
  for i in (start + 32)..<end {
    if self.window.unsafe_get(i) != b {
      return false
    }
  }
  // All same byte — emit one literal + repeated distance-1 matches.
  // Trailing bytes shorter than MIN_MATCH_LENGTH are emitted as literals.
  self.emit_uniform_tokens(b, start, end)
  self.w.write_dynamic_block(self.tokens, false)
  self.tokens.clear()
  self.index = end
  true
}

///|
/// Emit tokens for a uniform byte run: 1 literal + max-length distance-1 matches.
/// Trailing bytes shorter than MIN_MATCH_LENGTH are emitted as literals.
fn Deflater::emit_uniform_tokens(
  self : Deflater,
  b : Byte,
  start : Int,
  end : Int,
) -> Unit {
  self.tokens.push(Token::literal(b))
  let mut pos = start + 1
  while pos < end {
    let remaining = end - pos
    if remaining < MIN_MATCH_LENGTH {
      while pos < end {
        self.tokens.push(Token::literal(b))
        pos += 1
      }
      break
    }
    let len = if remaining < MAX_MATCH_LENGTH {
      remaining
    } else {
      MAX_MATCH_LENGTH
    }
    self.tokens.push(Token::match_(len, 1))
    pos += len
  }
}

///|
/// Detect and optimally encode uniform data via tokens (for levels 2+).
fn Deflater::encode_uniform_tokens(self : Deflater) -> Bool {
  let start = self.index
  let end = self.window_end
  if end - start < 32 {
    return false
  }
  let b = self.window.unsafe_get(start)
  for i in (start + 1)..<(start + 32) {
    if self.window.unsafe_get(i) != b {
      return false
    }
  }
  for i in (start + 32)..<end {
    if self.window.unsafe_get(i) != b {
      return false
    }
  }
  self.emit_uniform_tokens(b, start, end)
  self.w.write_dynamic_block(self.tokens, false)
  self.tokens.clear()
  self.index = end
  true
}

///|
fn Deflater::step_greedy(self : Deflater) -> Unit {
  let hash_mask = self.head.length() - 1
  let max_chain = if self.level == 2 { 8 } else { 16 }
  let end = self.window_end
  let mut i = self.index
  let safe_end = end - MIN_MATCH_LENGTH
  if i >= safe_end {
    self.index = i
    return
  }
  // Quick check: if data is uniform, encode optimally via tokens
  if self.encode_uniform_tokens() {
    return
  }
  while i < safe_end {
    // i < safe_end guarantees i+3 < end
    let match_head = self.insert_hash(i, hash_mask)
    if match_head >= 0 && i - match_head <= MAX_MATCH_OFFSET {
      let (length, offset) = self.find_best_match(i, match_head, max_chain)
      if length >= MIN_MATCH_LENGTH {
        self.tokens.push(Token::match_(length, offset))
        // Rehash a capped number of intermediate positions.
        let mi = max_insert(self.level)
        let n_insert = if length - 1 < mi { length - 1 } else { mi }
        let rehash_end = if i + n_insert + 4 < end {
          i + 1 + n_insert
        } else {
          end - 3
        }
        for pos in (i + 1)..<rehash_end {
          ignore(self.insert_hash(pos, hash_mask))
        }
        i += length
        if self.tokens.length() >= MAX_BLOCK_TOKENS {
          self.w.write_dynamic_block(self.tokens, false)
          self.tokens.clear()
        }
        continue
      }
    }
    self.tokens.push(Token::literal(self.window.unsafe_get(i)))
    i += 1
    if self.tokens.length() >= MAX_BLOCK_TOKENS {
      self.w.write_dynamic_block(self.tokens, false)
      self.tokens.clear()
    }
  }
  self.index = i
}

///|
fn Deflater::step_lazy(self : Deflater) -> Unit {
  let hash_mask = self.head.length() - 1
  let level = self.level
  let max_chain = match level {
    4 => 32
    5 => 64
    6 => 128
    7 => 256
    8 => 512
    _ => 1024
  }
  let good = match level {
    4 => 4
    5 | 6 | 7 => 8
    _ => 32
  }
  let lazy_thresh = match level {
    4 => 4
    5 | 6 => 16
    7 => 32
    8 => 128
    _ => 258
  }
  let nice = match level {
    4 => 16
    5 => 32
    6 | 7 => 128
    _ => 258
  }
  let mi = max_insert(level)
  let end = self.window_end
  let mut i = self.index
  let safe_end = end - MIN_MATCH_LENGTH
  if i >= safe_end {
    self.index = i
    return
  }
  // Quick check: if data is uniform, encode optimally via tokens
  if self.encode_uniform_tokens() {
    return
  }
  // Cache frequently-accessed fields in locals
  let window = self.window
  let head = self.head
  let prev = self.prev
  let tokens = self.tokens
  let base = self.base
  while i < safe_end {
    // i < safe_end guarantees i+3 < end
    let mut cur_len = 0
    let mut cur_dist = 0
    // Inline hash4 + insert_hash to avoid method call overhead
    let v = window.unsafe_get(i).to_int() |
      (window.unsafe_get(i + 1).to_int() << 8) |
      (window.unsafe_get(i + 2).to_int() << 16) |
      (window.unsafe_get(i + 3).to_int() << 24)
    let h = ((v.reinterpret_as_uint() * 0x1e35a7bdU).reinterpret_as_int() >> 17) &
      hash_mask
    let match_head_abs = head.unsafe_get(h)
    prev.unsafe_set(i & WINDOW_MASK, match_head_abs)
    head.unsafe_set(h, i + base)
    let match_head = match_head_abs - base
    // Skip match-finding when previous match exceeds lazy threshold
    if !(self.has_prev && self.prev_match_len >= lazy_thresh) &&
      match_head_abs >= base &&
      i - match_head <= MAX_MATCH_OFFSET {
      // Inlined find_best_match to reuse cached window/prev locals
      let mut best_len = MIN_MATCH_LENGTH - 1
      let mut best_offset = 0
      let mut pos = match_head
      let mut chain_count = 0
      let max_len = if end - i < MAX_MATCH_LENGTH {
        end - i
      } else {
        MAX_MATCH_LENGTH
      }
      // Halve chain when existing match already >= good
      let chain_limit = if self.has_prev && self.prev_match_len >= good {
        max_chain >> 1
      } else {
        max_chain
      }
      // Cache the comparison byte to avoid repeated array lookup
      let mut w_end = window.unsafe_get(i + best_len)
      while pos >= 0 && i - pos <= MAX_MATCH_OFFSET && chain_count < chain_limit {
        // Skip check: compare byte at best_len position first
        if window.unsafe_get(pos + best_len) != w_end {
          let next_abs = prev.unsafe_get(pos & WINDOW_MASK)
          if next_abs < base {
            break
          }
          let next = next_abs - base
          if next >= pos {
            break
          }
          pos = next
          chain_count += 1
          continue
        }
        let length = @blit.match_length(window, i, window, pos, max_len)
        if length > best_len {
          best_len = length
          best_offset = i - pos
          if best_len >= nice || best_len == max_len {
            break
          }
          w_end = window.unsafe_get(i + best_len)
        }
        let next_abs = prev.unsafe_get(pos & WINDOW_MASK)
        if next_abs < base {
          break
        }
        let next = next_abs - base
        if next >= pos {
          break
        }
        pos = next
        chain_count += 1
      }
      if best_len >= MIN_MATCH_LENGTH {
        cur_len = best_len
        cur_dist = best_offset
      }
    }
    if self.has_prev {
      if cur_len > self.prev_match_len + 1 {
        tokens.push(Token::literal(self.prev_literal))
        self.prev_match_len = cur_len
        self.prev_match_dist = cur_dist
        self.prev_literal = window.unsafe_get(i)
        i += 1
      } else {
        tokens.push(Token::match_(self.prev_match_len, self.prev_match_dist))
        let start = i
        let skip_end = start + self.prev_match_len - 1
        // Rehash a capped number of intermediate positions.
        let n_insert = if self.prev_match_len - 1 < mi {
          self.prev_match_len - 1
        } else {
          mi
        }
        let rehash_end = if start + n_insert + 3 < end {
          start + n_insert
        } else {
          end - 4
        }
        for j in start..<rehash_end {
          // Inline insert_hash to reuse cached locals
          let rv = window.unsafe_get(j).to_int() |
            (window.unsafe_get(j + 1).to_int() << 8) |
            (window.unsafe_get(j + 2).to_int() << 16) |
            (window.unsafe_get(j + 3).to_int() << 24)
          let rh = ((rv.reinterpret_as_uint() * 0x1e35a7bdU).reinterpret_as_int() >>
            17) &
            hash_mask
          prev.unsafe_set(j & WINDOW_MASK, head.unsafe_get(rh))
          head.unsafe_set(rh, j + base)
        }
        i = skip_end
        self.has_prev = false
      }
    } else if cur_len >= MIN_MATCH_LENGTH {
      self.has_prev = true
      self.prev_match_len = cur_len
      self.prev_match_dist = cur_dist
      self.prev_literal = window.unsafe_get(i)
      i += 1
    } else {
      tokens.push(Token::literal(window.unsafe_get(i)))
      i += 1
    }
    if tokens.length() >= MAX_BLOCK_TOKENS {
      self.w.write_dynamic_block(tokens, false)
      tokens.clear()
    }
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
    while self.index < self.window_end {
      self.tokens.push(Token::literal(self.window.unsafe_get(self.index)))
      self.index += 1
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
  let base = self.base
  while pos >= 0 && cur - pos <= MAX_MATCH_OFFSET && chain_count < max_chain {
    // Early exit: check the byte at best_len position first to skip
    // non-matching chain entries without calling match_len.
    if best_len > 0 &&
      window.unsafe_get(pos + best_len) != window.unsafe_get(cur + best_len) {
      let next_abs = prev.unsafe_get(pos & WINDOW_MASK)
      if next_abs < base {
        break
      }
      let next = next_abs - base
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
    let next_abs = prev.unsafe_get(pos & WINDOW_MASK)
    if next_abs < base {
      break
    }
    let next = next_abs - base
    if next >= pos {
      break
    }
    pos = next
    chain_count += 1
  }
  (best_len, best_offset)
}
