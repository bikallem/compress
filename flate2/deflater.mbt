///|
/// Phase of the deflate state machine.
priv enum DeflatePhase {
  Ready
  Finished
  Failed(CompressError)
}

///|
/// 4-byte hash for the hash chain, masked to hash_mask.
fn hash4(window : FixedArray[Byte], pos : Int, hash_mask : Int) -> Int {
  let v = window[pos].to_int() |
    (window[pos + 1].to_int() << 8) |
    (window[pos + 2].to_int() << 16) |
    (window[pos + 3].to_int() << 24)
  ((v & 0xFFFFFF) ^ (((v >> 16) & 0xFF) * 0x1e35a7bd)) & hash_mask
}

///|
/// Insert position into hash chain and return previous head.
fn insert_hash(
  window : FixedArray[Byte],
  pos : Int,
  head : FixedArray[Int],
  prev : FixedArray[Int],
  hash_mask : Int,
) -> Int {
  let h = hash4(window, pos, hash_mask)
  let match_head = head[h]
  prev[pos & WINDOW_MASK] = match_head
  head[h] = pos
  match_head
}

///|
const WINDOW_SIZE : Int = 1 << 15 // 32KB

///|
const WINDOW_MASK : Int = WINDOW_SIZE - 1

///|
const MAX_BLOCK_TOKENS : Int = 16384

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
            ignore(insert_hash(d.window, i, d.head, d.prev, hash_mask))
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
pub fn Deflater::encode(self : Deflater, data : Bytes?) -> Encode {
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
fn Deflater::feed(self : Deflater, data : Bytes) -> Encode {
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
    for i in 0..<n {
      self.window[self.window_end + i] = data[offset + i]
    }
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
fn Deflater::step(self : Deflater) -> Unit {
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
fn Deflater::step_stored(self : Deflater) -> Unit {
  while self.index < self.window_end {
    let remaining = self.window_end - self.index
    let block_len = if remaining > 65535 { 65535 } else { remaining }
    self.w.write_stored_header(block_len, false)
    self.w.write_stored_data(self.window, self.index, block_len)
    self.index += block_len
    ()
  }
}

///|
fn Deflater::step_fast(self : Deflater) -> Unit {
  let window = self.window
  let head = self.head
  let hash_mask = head.length() - 1
  let end = self.window_end
  let mut i = self.index
  let safe_end = end - MIN_MATCH_LENGTH
  if i >= safe_end {
    self.index = i
    return
  }
  self.w.start_fixed_block(false)
  while i < safe_end {
    if i + 3 < end {
      let h = hash4(window, i, hash_mask)
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
          if i + 4 < end {
            head[hash4(window, i + 1, hash_mask)] = i + 1
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
  ()
}

///|
fn Deflater::step_greedy(self : Deflater) -> Unit {
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
      let match_head = insert_hash(window, i, head, prev, hash_mask)
      if match_head >= 0 && i - match_head <= MAX_MATCH_OFFSET {
        let (length, offset) = find_best_match_window(
          window, end, i, match_head, prev, max_chain,
        )
        if length >= MIN_MATCH_LENGTH {
          self.tokens.push(Token::match_(length, offset))
          for j in 1..<length {
            let pos = i + j
            if pos + 3 < end {
              ignore(insert_hash(window, pos, head, prev, hash_mask))
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
  ()
}

///|
fn Deflater::step_lazy(self : Deflater) -> Unit {
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
      let match_head = insert_hash(window, i, head, prev, hash_mask)
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
        self.tokens.push(Token::literal(self.prev_literal))
        self.prev_match_len = cur_len
        self.prev_match_dist = cur_dist
        self.prev_literal = window[i]
        i += 1
      } else {
        self.tokens.push(
          Token::match_(self.prev_match_len, self.prev_match_dist),
        )
        let start = i
        let skip_end = start + self.prev_match_len - 1
        for j in start..<skip_end {
          if j + 3 < end {
            ignore(insert_hash(window, j, head, prev, hash_mask))
          }
        }
        i = skip_end
        self.has_prev = false
      }
    } else if cur_len >= MIN_MATCH_LENGTH {
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
  ()
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
  let window = self.window
  while self.index < self.window_end {
    if self.level <= 1 {
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
