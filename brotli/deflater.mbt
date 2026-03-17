///|
/// Phase of the Brotli deflate state machine.
priv enum BrotliDeflatePhase {
  Ready
  Finished
  Failed(BrotliError)
}

///|
/// Streaming, non-blocking Brotli compressor.
///
/// Quality 0-1 only (fast fragment-based compression).
struct Deflater {
  quality : Int
  bw : BrotliBitWriter
  mut phase : BrotliDeflatePhase
  // Hash table for match finding
  table : FixedArray[Int]
  table_bits : Int
  // Buffer for input data
  buf : FixedArray[Byte]
  mut buf_len : Int
  // Stream header written?
  mut header_written : Bool
}

///|
pub fn Deflater::new(quality? : Int = 1) -> Deflater {
  let q = if quality < 0 { 0 } else if quality > 1 { 1 } else { quality }
  let table_bits = if q == 0 { 15 } else { 17 }
  let table_size = 1 << table_bits
  {
    quality: q,
    bw: BrotliBitWriter::new(),
    phase: Ready,
    table: FixedArray::make(table_size, 0),
    table_bits,
    buf: FixedArray::make(1 << 18, b'\x00'), // 256KB buffer
    buf_len: 0,
    header_written: false,
  }
}

///|
/// Single entry point for encoding.
///   encode(Some(data)) — feed input to compress
///   encode(None)       — signal end of input, flush final block
pub fn Deflater::encode(self : Deflater, data : BytesView?) -> Encode {
  match self.phase {
    Failed(e) => Encode::Error(e)
    Finished => Encode::End
    Ready =>
      match data {
        Some(chunk) => self.feed(chunk)
        None => self.do_finish()
      }
  }
}

///|
fn Deflater::write_stream_header(self : Deflater) -> Unit {
  if self.header_written {
    return
  }
  self.header_written = true
  // Write stream header: window bits = 18 (256KB window)
  // Encoding: bit 0 = 1 (not 16 bits), then 3 bits = 1 (17+1=18)
  self.bw.write_bits(1, 1UL) // not WBITS=16
  self.bw.write_bits(3, 1UL) // WBITS = 17 + 1 = 18
}

///|
fn Deflater::feed(self : Deflater, data : BytesView) -> Encode {
  if data.length() == 0 {
    return Encode::Ok
  }
  self.write_stream_header()
  let max_block = 1 << 18 // 256KB max metablock
  let mut offset = 0
  while offset < data.length() {
    let avail = max_block - self.buf_len
    let n = if data.length() - offset < avail {
      data.length() - offset
    } else {
      avail
    }
    for i in 0..<n {
      self.buf[self.buf_len + i] = data[offset + i]
    }
    self.buf_len += n
    offset += n
    if self.buf_len >= max_block {
      self.flush_block(false)
      // Return intermediate output if available
      let output = self.bw.take_output()
      if output.length() > 0 {
        return Encode::Data(output)
      }
    }
  }
  Encode::Ok
}

///|
fn Deflater::flush_block(self : Deflater, is_last : Bool) -> Unit {
  if self.buf_len == 0 && !is_last {
    return
  }
  encode_fragment(
    self.buf,
    0,
    self.buf_len,
    is_last,
    self.bw,
    self.table,
    self.table_bits,
  )
  // Reset buffer but keep hash table for cross-block matching
  self.buf_len = 0
}

///|
fn Deflater::do_finish(self : Deflater) -> Encode {
  self.write_stream_header()
  self.flush_block(true)
  let output = self.bw.take_output()
  self.phase = Finished
  if output.length() > 0 {
    Encode::Data(output)
  } else {
    Encode::End
  }
}
