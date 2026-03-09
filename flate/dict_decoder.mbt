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
  // Safety: caller ensures avail_write() > 0
  self.hist.unsafe_set(self.wr_pos, b)
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
  if src_pos + max_copy <= hist_len && src_pos + max_copy <= dst_base {
    // Non-overlapping, no wrap: bulk copy
    @blit.blit_fixed_array(hist, dst_base, hist, src_pos, max_copy)
  } else if dist == 1 {
    // RLE: fill with single byte using vectorized memset
    @blit.fill_bytes(
      hist,
      dst_base,
      hist.unsafe_get(src_pos).to_int(),
      max_copy,
    )
  } else if src_pos < dst_base && src_pos + max_copy <= hist_len {
    // Overlapping forward copy, no wrap — copy in dist-sized chunks
    let mut dst_pos = dst_base
    let dst_end = dst_base + max_copy
    while dst_pos + dist <= dst_end {
      @blit.blit_fixed_array(hist, dst_pos, hist, dst_pos - dist, dist)
      dst_pos += dist
    }
    if dst_pos < dst_end {
      @blit.blit_fixed_array(
        hist,
        dst_pos,
        hist,
        dst_pos - dist,
        dst_end - dst_pos,
      )
    }
  } else {
    // General case: byte-at-a-time with wrap handling
    let mut dst_pos = dst_base
    let mut sp = src_pos
    let dst_end = dst_base + max_copy
    // Safety: dst_pos < dst_end <= hist_len, sp wraps within [0, hist_len)
    while dst_pos < dst_end {
      hist.unsafe_set(dst_pos, hist.unsafe_get(sp))
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
fn DictDecoder::read_flush(self : DictDecoder, out : OutputBuffer) -> Unit {
  if self.wr_pos > self.rd_pos {
    out.write_fixed(self.hist, self.rd_pos, self.wr_pos - self.rd_pos)
  }
  // After flush, wrap both pointers if at end of buffer
  if self.wr_pos == self.hist.length() {
    self.wr_pos = 0
    self.full = true
  }
  self.rd_pos = self.wr_pos
}

///|
/// Reads available bytes and writes them to a @stream.Writer.
fn DictDecoder::flush_to_writer(
  self : DictDecoder,
  writer : &@stream.Writer,
) -> Unit raise @stream.StreamError {
  if self.wr_pos > self.rd_pos {
    let len = self.wr_pos - self.rd_pos
    writer.write(
      self.hist.unsafe_reinterpret_as_bytes()[self.rd_pos:self.rd_pos + len],
    )
  }
  if self.wr_pos == self.hist.length() {
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
