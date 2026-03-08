///|
/// DeflateWriter compresses data using DEFLATE and pushes to a dest `@stream.Writer`.
///
/// Implements `@stream.Writer` — push-based, accepts BytesView chunks.
/// True streaming: processes input incrementally with constant memory (~450KB).
pub struct DeflateWriter {
  priv compressor : StreamingCompressor
  priv forward_eod : Bool
  priv mut closed : Bool
}

///|
pub fn DeflateWriter::new(
  dest : &@stream.Writer,
  level? : CompressionLevel = DefaultCompression,
  dict? : Bytes = Bytes::default(),
  forward_eod? : Bool = true,
) -> DeflateWriter {
  let lvl = level.to_int()
  let c = StreamingCompressor::new(dest, lvl)
  // Preload dictionary into window if provided
  if dict.length() > 0 {
    let dict_len = if dict.length() > WINDOW_SIZE {
      WINDOW_SIZE
    } else {
      dict.length()
    }
    let dict_start = dict.length() - dict_len
    for i in 0..<dict_len {
      c.window[i] = dict[dict_start + i]
    }
    c.window_end = dict_len
    c.index = dict_len
    c.block_start = dict_len
    // Hash the dictionary so matches can reference it
    if lvl >= 1 {
      let head = c.head
      let prev = c.prev
      let hash_mask = head.length() - 1
      let window = c.window
      for i in 0..<(dict_len - 3) {
        let b0 = window[i].to_int()
        let b1 = window[i + 1].to_int()
        let b2 = window[i + 2].to_int()
        let b3 = window[i + 3].to_int()
        let v = b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
        let h = ((v & 0xFFFFFF) ^ (((v >> 16) & 0xFF) * 0x1e35a7bd)) & hash_mask
        prev[i & WINDOW_MASK] = head[h]
        head[h] = i
      }
    }
  }
  { compressor: c, forward_eod, closed: false }
}

///|
pub impl @stream.Writer for DeflateWriter with write(self, data) {
  if data.is_empty() {
    if not(self.closed) {
      self.closed = true
      self.compressor.finish()
      if self.forward_eod {
        self.compressor.w.dest.write(b""[:])
      }
    }
    return
  }
  // Feed data incrementally
  let mut offset = 0
  while offset < data.length() {
    let consumed = self.compressor.fill(data[offset:])
    offset += consumed
    self.compressor.step()
  }
}
