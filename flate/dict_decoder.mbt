///|
/// DictDecoder implements the 32KB sliding window for DEFLATE decompression.
priv struct DictDecoder {
  hist : FixedArray[Byte]
  mut wr_pos : Int
  mut rd_pos : Int
  mut full : Bool
}

///|
fn DictDecoder::new(size? : Int = 32768) -> DictDecoder {
  { hist: FixedArray::make(size, b'\x00'), wr_pos: 0, rd_pos: 0, full: false }
}

///|
fn DictDecoder::init_dict(self : DictDecoder, dict : Bytes) -> Unit {
  let n = if dict.length() > self.hist.length() {
    dict.length() - self.hist.length()
  } else {
    0
  }
  let copy_len = dict.length() - n
  for i in 0..<copy_len {
    self.hist[i] = dict[n + i]
  }
  self.wr_pos = copy_len
  if self.wr_pos == self.hist.length() {
    self.wr_pos = 0
    self.full = true
  }
  self.rd_pos = self.wr_pos
}

///|
/// Returns the number of bytes available for reading.
fn DictDecoder::_avail_read(self : DictDecoder) -> Int {
  self.wr_pos - self.rd_pos
}

///|
/// Returns the number of bytes available for writing.
fn DictDecoder::avail_write(self : DictDecoder) -> Int {
  self.hist.length() - self.wr_pos
}

///|
/// Writes a single byte.
fn DictDecoder::write_byte(self : DictDecoder, b : Byte) -> Unit {
  self.hist[self.wr_pos] = b
  self.wr_pos += 1
}

///|
/// Copies `length` bytes from `dist` bytes back in the history.
/// Returns the number of bytes actually copied.
fn DictDecoder::write_copy(self : DictDecoder, dist : Int, length : Int) -> Int {
  let hist_len = self.hist.length()
  let dst_base = self.wr_pos
  let max_copy = if dst_base + length > hist_len {
    hist_len - dst_base
  } else {
    length
  }
  let mut src_pos = dst_base - dist
  if src_pos < 0 {
    src_pos += hist_len
  }
  let hist = self.hist
  // Fast path: source doesn't wrap and no overlap with destination
  if src_pos + max_copy <= hist_len && src_pos + max_copy <= dst_base {
    // Non-overlapping bulk copy
    FixedArray::unsafe_blit(hist, dst_base, hist, src_pos, max_copy)
  } else if dist == 1 {
    // Run-length encoding: fill with single byte (very common case)
    let fill_byte = hist[src_pos]
    for i in dst_base..<(dst_base + max_copy) {
      hist[i] = fill_byte
    }
  } else {
    // General case: byte-at-a-time with wrap handling
    let mut dst_pos = dst_base
    let mut sp = src_pos
    let dst_end = dst_base + max_copy
    while dst_pos < dst_end {
      hist[dst_pos] = hist[sp]
      dst_pos += 1
      sp += 1
      if sp == hist_len {
        sp = 0
      }
    }
  }
  self.wr_pos += max_copy
  max_copy
}

///|
/// Writes a slice of bytes.
fn DictDecoder::_write_slice(self : DictDecoder, data : BytesView) -> Int {
  let avail = self.avail_write()
  let n = if data.length() > avail { avail } else { data.length() }
  for i in 0..<n {
    self.hist[self.wr_pos + i] = data[i]
  }
  self.wr_pos += n
  n
}

///|
/// Reads available bytes into the output buffer.
fn DictDecoder::read_flush(self : DictDecoder, out : @buffer.Buffer) -> Unit {
  let hist = self.hist
  if self.wr_pos > self.rd_pos {
    let mut i = self.rd_pos
    let end = self.wr_pos
    while i < end {
      out.write_byte(hist[i])
      i += 1
    }
  }
  // After flush, wrap both pointers if at end of buffer
  if self.wr_pos == hist.length() {
    self.wr_pos = 0
    self.full = true
  }
  self.rd_pos = self.wr_pos
}

///|
/// Writes available bytes to a writer (async streaming output).
async fn DictDecoder::flush_to_writer(
  self : DictDecoder,
  writer : &@io.Writer,
) -> Unit {
  let hist = self.hist
  if self.wr_pos > self.rd_pos {
    let bytes = hist.unsafe_reinterpret_as_bytes()
    let mut offset = self.rd_pos
    let end = self.wr_pos
    while offset < end {
      let written = writer.write_once(bytes, offset~, len=end - offset)
      offset += written
    }
  }
  if self.wr_pos == hist.length() {
    self.wr_pos = 0
    self.full = true
  }
  self.rd_pos = self.wr_pos
}

///|
/// Returns the total number of bytes in the history.
fn DictDecoder::hist_size(self : DictDecoder) -> Int {
  if self.full {
    self.hist.length()
  } else {
    self.wr_pos
  }
}
