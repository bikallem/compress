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
fn DictDecoder::avail_read(self : DictDecoder) -> Int {
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
  if self.wr_pos == self.hist.length() {
    self.wr_pos = 0
    self.full = true
  }
}

///|
/// Copies `length` bytes from `dist` bytes back in the history.
/// Returns the number of bytes actually copied.
fn DictDecoder::write_copy(self : DictDecoder, dist : Int, length : Int) -> Int {
  let dst_base = self.wr_pos
  let mut dst_pos = dst_base
  let mut src_pos = dst_base - dist
  if src_pos < 0 {
    src_pos += self.hist.length()
  }
  let dst_end = if dst_base + length > self.hist.length() {
    self.hist.length()
  } else {
    dst_base + length
  }
  while dst_pos < dst_end {
    self.hist[dst_pos] = self.hist[src_pos]
    dst_pos += 1
    src_pos += 1
    if src_pos == self.hist.length() {
      src_pos = 0
    }
  }
  let n = dst_pos - dst_base
  self.wr_pos += n
  if self.wr_pos == self.hist.length() {
    self.wr_pos = 0
    self.full = true
  }
  n
}

///|
/// Writes a slice of bytes.
fn DictDecoder::write_slice(self : DictDecoder, data : BytesView) -> Int {
  let avail = self.avail_write()
  let n = if data.length() > avail { avail } else { data.length() }
  for i in 0..<n {
    self.hist[self.wr_pos + i] = data[i]
  }
  self.wr_pos += n
  if self.wr_pos == self.hist.length() {
    self.wr_pos = 0
    self.full = true
  }
  n
}

///|
/// Reads available bytes into the output buffer.
fn DictDecoder::read_flush(self : DictDecoder, out : @buffer.Buffer) -> Unit {
  if self.wr_pos > self.rd_pos {
    for i in self.rd_pos..<self.wr_pos {
      out.write_byte(self.hist[i])
    }
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
