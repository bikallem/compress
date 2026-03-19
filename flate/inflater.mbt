///|
/// Phase of the inflate state machine.
priv enum InflatePhase {
  BlockHeader
  StoredInit
  StoredCopy(Int) // remaining bytes
  DynamicHeader
  HuffmanLoop(HuffmanDecoder, HuffmanDecoder)
  // Partial match decode states (suspended mid-symbol)
  HuffmanMatchLen(HuffmanDecoder, HuffmanDecoder, Int, Int) // lit_dec, dist_dec, length_code, extra_bits
  HuffmanMatchDist(HuffmanDecoder, HuffmanDecoder, Int) // lit_dec, dist_dec, length
  HuffmanMatchDistExtra(HuffmanDecoder, HuffmanDecoder, Int, Int, Int) // lit_dec, dist_dec, length, dist_sym, dextra
  HuffmanMatchCopy(HuffmanDecoder, HuffmanDecoder, Int, Int) // lit_dec, dist_dec, dist, remaining
  Done
  Failed(CompressError)
}

///|
/// Streaming, non-blocking DEFLATE decompressor.
///
/// The caller drives the decode loop:
///   - `decode()` returns `Await` when more input is needed
///   - `decode()` returns `Data(bytes)` when output is available
///   - `decode()` returns `End` when the stream is complete
///   - `decode()` returns `Error(e)` on format errors
struct Inflater {
  bb : BitBuf
  dd : DictDecoder
  mut phase : InflatePhase
  mut final_block : Bool
  mut pending_output : Bytes // buffered Data to emit before resuming
  mut sink : @output_sink.OutputSink? // None = streaming, Some = direct output
  mut redispatch : Bool // trampoline flag: phase changed, re-dispatch in decode() loop
}

///|
pub fn Inflater::new(dict? : Bytes) -> Inflater {
  let dd = DictDecoder::new()
  match dict {
    Some(d) => if d.length() > 0 { dd.init_dict(d) }
    None => ()
  }
  {
    bb: BitBuf::new(),
    dd,
    phase: BlockHeader,
    final_block: false,
    pending_output: Bytes::default(),
    sink: None,
    redispatch: false,
  }
}

///|
/// Feed input bytes. Only valid after decode() returned Await.
pub fn Inflater::src(self : Inflater, data : BytesView) -> Unit {
  self.bb.set_input(data)
}

///|
/// Advance the decoder one step.
pub fn Inflater::decode(self : Inflater) -> Decode {
  for ;; {
    // Emit pending output first
    if self.pending_output.length() > 0 {
      let out = self.pending_output
      self.pending_output = Bytes::default()
      return Data(out)
    }
    self.redispatch = false
    let result : Decode = match self.phase {
      Done => End
      Failed(e) => Error(e)
      BlockHeader => self.decode_block_header()
      StoredInit => self.decode_stored_init()
      StoredCopy(remaining) => self.decode_stored_copy(remaining)
      DynamicHeader => self.decode_dynamic_header()
      HuffmanLoop(lit_dec, dist_dec) =>
        self.decode_huffman_loop(lit_dec, dist_dec)
      HuffmanMatchLen(lit_dec, dist_dec, length_code, extra_bits) =>
        self.decode_huffman_match_len(lit_dec, dist_dec, length_code, extra_bits)
      HuffmanMatchDist(lit_dec, dist_dec, length) =>
        self.decode_huffman_match_dist(lit_dec, dist_dec, length)
      HuffmanMatchDistExtra(lit_dec, dist_dec, length, dist_sym, dextra) =>
        self.decode_huffman_match_dist_extra(
          lit_dec, dist_dec, length, dist_sym, dextra,
        )
      HuffmanMatchCopy(lit_dec, dist_dec, dist, remaining) =>
        self.decode_huffman_match_copy(lit_dec, dist_dec, dist, remaining)
    }
    if self.redispatch {
      continue
    }
    return result
  }
}

///|
/// After End: bytes from input not consumed by the DEFLATE stream.
pub fn Inflater::remaining(self : Inflater) -> Bytes {
  self.bb.remaining()
}

///|
/// Enable zero-copy direct output mode. Decoded bytes accumulate in
/// an internal buffer instead of being returned as individual Data chunks.
/// Call `take_output()` after `End` to retrieve the result.
fn Inflater::enable_direct_output(self : Inflater, capacity : Int) -> Unit {
  self.sink = Some(@output_sink.OutputSink::new(capacity))
}

///|
fn Inflater::emit_output(self : Inflater) -> Bytes {
  match self.sink {
    Some(sink) => {
      self.dd.flush_to(sink)
      Bytes::default()
    }
    None => self.dd.flush()
  }
}

///|
fn Inflater::take_output(self : Inflater) -> Bytes {
  match self.sink {
    Some(sink) => sink.to_bytes()
    None => Bytes::default()
  }
}

///|
fn Inflater::fail(self : Inflater, e : CompressError) -> Decode {
  self.phase = Failed(e)
  Error(e)
}

///|
fn Inflater::decode_block_header(self : Inflater) -> Decode {
  if !self.bb.ensure(3) {
    return Await
  }
  let bfinal = self.bb.read_unchecked(1)
  self.final_block = bfinal != 0
  let btype = self.bb.read_unchecked(2)
  match btype {
    0 => {
      self.phase = StoredInit
      self.redispatch = true
      Await
    }
    1 => {
      self.phase = HuffmanLoop(fixed_lit_decoder, fixed_dist_decoder)
      self.redispatch = true
      Await
    }
    2 => {
      self.phase = DynamicHeader
      self.redispatch = true
      Await
    }
    _ => self.fail(CompressError::CorruptInput("invalid block type \{btype}"))
  }
}

///|
fn Inflater::decode_stored_init(self : Inflater) -> Decode {
  self.bb.align_to_byte()
  if !self.bb.ensure(32) {
    return Await
  }
  let len = self.bb.read_unchecked(16)
  let nlen = self.bb.read_unchecked(16)
  if (len ^ nlen) != 0xFFFF {
    return self.fail(
      CompressError::CorruptInput("invalid stored block lengths"),
    )
  }
  self.phase = StoredCopy(len)
  self.redispatch = true
  Await
}

///|
fn Inflater::decode_stored_copy(self : Inflater, remaining : Int) -> Decode {
  if remaining == 0 {
    let flushed = self.emit_output()
    if self.final_block {
      self.phase = Done
      if flushed.length() > 0 {
        self.pending_output = Bytes::default()
        return Data(flushed)
      }
      return End
    }
    self.phase = BlockHeader
    if flushed.length() > 0 {
      return Data(flushed)
    }
    self.redispatch = true
    return Await
  }
  // First drain any whole bytes from bit buffer
  let bb = self.bb
  let dd = self.dd
  let hist = dd.hist
  let hist_len = hist.length()
  let mut rem = remaining
  while rem > 0 && bb.count >= 8 {
    dd.write_byte((bb.buf & 0xFFUL).to_byte())
    bb.buf = bb.buf >> 8
    bb.count -= 8
    rem -= 1
    if dd.wr_pos == hist_len {
      let flushed = self.emit_output()
      self.phase = StoredCopy(rem)
      if flushed.length() > 0 {
        return Data(flushed)
      }
      continue
    }
  }
  // Copy from input directly
  while rem > 0 {
    let chunk = bb.next_bytes(
      if rem < dd.avail_write() {
        rem
      } else {
        dd.avail_write()
      },
    )
    if chunk.length() == 0 {
      self.phase = StoredCopy(rem)
      // Flush any pending output before requesting more input
      let flushed = self.emit_output()
      if flushed.length() > 0 {
        self.pending_output = Bytes::default()
        return Data(flushed)
      }
      return Await
    }
    for i, b in chunk {
      hist[dd.wr_pos + i] = b
    }
    dd.wr_pos += chunk.length()
    rem -= chunk.length()
    if dd.wr_pos == hist_len {
      let flushed = self.emit_output()
      self.phase = StoredCopy(rem)
      if flushed.length() > 0 {
        return Data(flushed)
      }
      continue
    }
  }
  // All copied
  let flushed = self.emit_output()
  if self.final_block {
    self.phase = Done
    if flushed.length() > 0 {
      return Data(flushed)
    }
    return End
  }
  self.phase = BlockHeader
  if flushed.length() > 0 {
    return Data(flushed)
  }
  self.redispatch = true
  Await
}

///|
fn Inflater::decode_dynamic_header(self : Inflater) -> Decode {
  let bb = self.bb
  // Need at least 14 bits for HLIT(5) + HDIST(5) + HCLEN(4)
  if !bb.ensure(14) {
    return Await
  }
  let hlit = bb.read_unchecked(5) + 257
  let hdist = bb.read_unchecked(5) + 1
  let hclen = bb.read_unchecked(4) + 4
  // Need 3 bits per code length
  if !bb.ensure(hclen * 3) {
    // This is tricky — we've already consumed the header bits.
    // For simplicity, require enough input to parse the whole dynamic header.
    return self.fail(
      CompressError::CorruptInput(
        "truncated dynamic header (need more input for code lengths)",
      ),
    )
  }
  let cl_lengths = FixedArray::make(NUM_CODES, 0)
  for i in 0..<hclen {
    cl_lengths[code_order[i]] = bb.read_unchecked(3)
  }
  let cl_decoder = HuffmanDecoder::build(cl_lengths) catch {
    e => return self.fail(CompressError::CorruptInput(e.to_string()))
  }
  let total = hlit + hdist
  let lengths = FixedArray::make(total, 0)
  let mut i = 0
  while i < total {
    let sym = match cl_decoder.decode(bb) {
      None =>
        return self.fail(
          CompressError::CorruptInput(
            "truncated dynamic header (need more input for code table)",
          ),
        )
      Some(s) => s
    }
    match sym {
      _ if sym <= CL_MAX_LIT => {
        lengths[i] = sym
        i += 1
      }
      CL_REPEAT_PREV => {
        guard i > 0 else {
          return self.fail(
            CompressError::CorruptInput("repeat with no previous length"),
          )
        }
        let count = match bb.read(2) {
          None =>
            return self.fail(
              CompressError::CorruptInput("truncated dynamic header"),
            )
          Some(v) => v + 3
        }
        let prev = lengths[i - 1]
        for _ in 0..<count {
          guard i < total else {
            return self.fail(
              CompressError::CorruptInput("too many code lengths"),
            )
          }
          lengths[i] = prev
          i += 1
        }
      }
      CL_REPEAT_ZERO_SHORT | CL_REPEAT_ZERO_LONG => {
        let (bits, base) = if sym == CL_REPEAT_ZERO_SHORT {
          (3, 3)
        } else {
          (7, 11)
        }
        let count = match bb.read(bits) {
          None =>
            return self.fail(
              CompressError::CorruptInput("truncated dynamic header"),
            )
          Some(v) => v + base
        }
        for _ in 0..<count {
          guard i < total else {
            return self.fail(
              CompressError::CorruptInput("too many code lengths"),
            )
          }
          lengths[i] = 0
          i += 1
        }
      }
      _ =>
        return self.fail(
          CompressError::CorruptInput("invalid code length symbol \{sym}"),
        )
    }
  }
  let lit_lengths = FixedArray::make(hlit, 0)
  for j in 0..<hlit {
    lit_lengths[j] = lengths[j]
  }
  let dist_lengths = FixedArray::make(hdist, 0)
  for j in 0..<hdist {
    dist_lengths[j] = lengths[hlit + j]
  }
  let lit_dec = HuffmanDecoder::build(lit_lengths) catch {
    e => return self.fail(CompressError::CorruptInput(e.to_string()))
  }
  let dist_dec = HuffmanDecoder::build(dist_lengths) catch {
    e => return self.fail(CompressError::CorruptInput(e.to_string()))
  }
  self.phase = HuffmanLoop(lit_dec, dist_dec)
  self.redispatch = true
  Await
}

///|
fn Inflater::decode_huffman_loop(
  self : Inflater,
  lit_dec : HuffmanDecoder,
  dist_dec : HuffmanDecoder,
) -> Decode {
  let bb = self.bb
  let dd = self.dd
  let hist = dd.hist
  let hist_len = hist.length()
  let chunk_mask = (1UL << HUFFMAN_CHUNK_BITS) - 1UL
  let lit_chunks = lit_dec.chunks
  let lit_min_bits = lit_dec.min_bits
  let lit_max_bits = lit_dec.max_bits
  let lit_links = lit_dec.links
  let link_suffix_mask = (1 << (lit_max_bits - HUFFMAN_CHUNK_BITS)) - 1
  // Cache bit reader and dict decoder state in locals for register allocation
  let input = bb.input
  let input_len = input.length()
  let mut buf = bb.buf
  let mut count = bb.count
  let mut pos = bb.pos
  let mut wr_pos = dd.wr_pos
  while true {
    // Inline fill(): pack bytes from input into bit accumulator
    while count <= 56 && pos < input_len {
      buf = buf | (input[pos].to_uint64() << count)
      count += 8
      pos += 1
    }
    if count < lit_min_bits {
      // Write back locals and flush
      bb.buf = buf
      bb.count = count
      bb.pos = pos
      dd.wr_pos = wr_pos
      let flushed = self.emit_output()
      wr_pos = dd.wr_pos
      self.phase = HuffmanLoop(lit_dec, dist_dec)
      if flushed.length() > 0 {
        return Data(flushed)
      }
      return Await
    }
    // Inline Huffman decode for literal/length
    let entry = lit_chunks.unsafe_get((buf & chunk_mask).to_int())
    let sym = if (entry & 0x80U) == 0U &&
      count >= (entry & 0xFFU).reinterpret_as_int() {
      let n = (entry & 0xFFU).reinterpret_as_int()
      let s = (entry >> 8).reinterpret_as_int()
      buf = buf >> n
      count -= n
      s
    } else if (entry & 0x80U) != 0U {
      let link_idx = (entry >> 8).reinterpret_as_int()
      let link_table = lit_links.unsafe_get(link_idx)
      let suffix = (buf >> HUFFMAN_CHUNK_BITS).to_int() & link_suffix_mask
      let link_entry = link_table.unsafe_get(suffix)
      let n = (link_entry & 0xFFU).reinterpret_as_int()
      if count < n {
        bb.buf = buf
        bb.count = count
        bb.pos = pos
        dd.wr_pos = wr_pos
        let flushed = self.emit_output()
        self.phase = HuffmanLoop(lit_dec, dist_dec)
        if flushed.length() > 0 {
          return Data(flushed)
        }
        return Await
      }
      let s = (link_entry >> 8).reinterpret_as_int()
      buf = buf >> n
      count -= n
      s
    } else {
      // Not enough bits — write back locals, use slow path
      bb.buf = buf
      bb.count = count
      bb.pos = pos
      dd.wr_pos = wr_pos
      match lit_dec.decode(bb) {
        Some(s) => {
          // Re-read after decode modified bb
          buf = bb.buf
          count = bb.count
          pos = bb.pos
          s
        }
        None => {
          let flushed = self.emit_output()
          wr_pos = dd.wr_pos
          self.phase = HuffmanLoop(lit_dec, dist_dec)
          if flushed.length() > 0 {
            return Data(flushed)
          }
          return Await
        }
      }
    }
    if sym < 256 {
      hist.unsafe_set(wr_pos, sym.to_byte())
      wr_pos += 1
      if wr_pos == hist_len {
        bb.buf = buf
        bb.count = count
        bb.pos = pos
        dd.wr_pos = wr_pos
        let flushed = self.emit_output()
        wr_pos = dd.wr_pos
        self.phase = HuffmanLoop(lit_dec, dist_dec)
        if flushed.length() > 0 {
          return Data(flushed)
        }
        continue
      }
    } else if sym == END_BLOCK_MARKER {
      bb.buf = buf
      bb.count = count
      bb.pos = pos
      dd.wr_pos = wr_pos
      let flushed = self.emit_output()
      if self.final_block {
        self.phase = Done
        if flushed.length() > 0 {
          return Data(flushed)
        }
        return End
      }
      self.phase = BlockHeader
      if flushed.length() > 0 {
        return Data(flushed)
      }
      self.redispatch = true
      return Await
    } else {
      // Length/distance pair — write back locals, delegate to existing methods
      bb.buf = buf
      bb.count = count
      bb.pos = pos
      dd.wr_pos = wr_pos
      let length_code = sym - 257
      if length_code >= length_base.length() {
        return self.fail(
          CompressError::CorruptInput("invalid length code \{sym}"),
        )
      }
      let extra = length_extra.unsafe_get(length_code)
      if extra > 0 {
        if !bb.ensure(extra) {
          let flushed = self.emit_output()
          self.phase = HuffmanMatchLen(lit_dec, dist_dec, length_code, extra)
          if flushed.length() > 0 {
            return Data(flushed)
          }
          return Await
        }
        let extra_val = bb.read_unchecked(extra)
        let length = length_base.unsafe_get(length_code) + extra_val
        return self.decode_huffman_match_dist_inline(lit_dec, dist_dec, length)
      } else {
        let length = length_base.unsafe_get(length_code)
        return self.decode_huffman_match_dist_inline(lit_dec, dist_dec, length)
      }
    }
  }
  // unreachable
  End
}

///|
fn Inflater::decode_huffman_match_len(
  self : Inflater,
  lit_dec : HuffmanDecoder,
  dist_dec : HuffmanDecoder,
  length_code : Int,
  extra : Int,
) -> Decode {
  if !self.bb.ensure(extra) {
    return Await
  }
  let extra_val = self.bb.read_unchecked(extra)
  let length = length_base.unsafe_get(length_code) + extra_val
  self.decode_huffman_match_dist_inline(lit_dec, dist_dec, length)
}

///|
fn Inflater::decode_huffman_match_dist_inline(
  self : Inflater,
  lit_dec : HuffmanDecoder,
  dist_dec : HuffmanDecoder,
  length : Int,
) -> Decode {
  let bb = self.bb
  bb.fill()
  let chunk_mask = (1UL << HUFFMAN_CHUNK_BITS) - 1UL
  let dist_chunks = dist_dec.chunks
  let dist_entry = dist_chunks.unsafe_get((bb.buf & chunk_mask).to_int())
  let dist_sym = if (dist_entry & 0x80U) == 0U &&
    bb.count >= (dist_entry & 0xFFU).reinterpret_as_int() {
    let n = (dist_entry & 0xFFU).reinterpret_as_int()
    let s = (dist_entry >> 8).reinterpret_as_int()
    bb.buf = bb.buf >> n
    bb.count -= n
    s
  } else if (dist_entry & 0x80U) != 0U {
    let link_idx = (dist_entry >> 8).reinterpret_as_int()
    let link_table = dist_dec.links.unsafe_get(link_idx)
    let suffix = (bb.buf >> HUFFMAN_CHUNK_BITS).to_int() &
      ((1 << (dist_dec.max_bits - HUFFMAN_CHUNK_BITS)) - 1)
    let link_entry = link_table.unsafe_get(suffix)
    let n = (link_entry & 0xFFU).reinterpret_as_int()
    if bb.count < n {
      self.phase = HuffmanMatchDist(lit_dec, dist_dec, length)
      return Await
    }
    let s = (link_entry >> 8).reinterpret_as_int()
    bb.buf = bb.buf >> n
    bb.count -= n
    s
  } else {
    match dist_dec.decode(bb) {
      Some(s) => s
      None => {
        self.phase = HuffmanMatchDist(lit_dec, dist_dec, length)
        return Await
      }
    }
  }
  if dist_sym >= dist_base.length() {
    return self.fail(
      CompressError::CorruptInput("invalid distance code \{dist_sym}"),
    )
  }
  let dextra = dist_extra.unsafe_get(dist_sym)
  if dextra > 0 {
    if !bb.ensure(dextra) {
      // dist_sym already decoded — save it so we don't re-decode on resume
      self.phase = HuffmanMatchDistExtra(
        lit_dec, dist_dec, length, dist_sym, dextra,
      )
      return Await
    }
    let dextra_val = bb.read_unchecked(dextra)
    let dist = dist_base.unsafe_get(dist_sym) + dextra_val
    if dist > self.dd.hist_size() {
      return self.fail(
        CompressError::CorruptInput(
          "distance \{dist} exceeds history \{self.dd.hist_size()}",
        ),
      )
    }
    self.do_copy(lit_dec, dist_dec, dist, length)
  } else {
    let dist = dist_base.unsafe_get(dist_sym)
    if dist > self.dd.hist_size() {
      return self.fail(
        CompressError::CorruptInput(
          "distance \{dist} exceeds history \{self.dd.hist_size()}",
        ),
      )
    }
    self.do_copy(lit_dec, dist_dec, dist, length)
  }
}

///|
fn Inflater::decode_huffman_match_dist(
  self : Inflater,
  lit_dec : HuffmanDecoder,
  dist_dec : HuffmanDecoder,
  length : Int,
) -> Decode {
  self.decode_huffman_match_dist_inline(lit_dec, dist_dec, length)
}

///|
/// Resume distance decode when dist_sym was already decoded but extra bits were missing.
fn Inflater::decode_huffman_match_dist_extra(
  self : Inflater,
  lit_dec : HuffmanDecoder,
  dist_dec : HuffmanDecoder,
  length : Int,
  dist_sym : Int,
  dextra : Int,
) -> Decode {
  if !self.bb.ensure(dextra) {
    return Await
  }
  let dextra_val = self.bb.read_unchecked(dextra)
  let dist = dist_base.unsafe_get(dist_sym) + dextra_val
  if dist > self.dd.hist_size() {
    return self.fail(
      CompressError::CorruptInput(
        "distance \{dist} exceeds history \{self.dd.hist_size()}",
      ),
    )
  }
  self.do_copy(lit_dec, dist_dec, dist, length)
}

///|
fn Inflater::do_copy(
  self : Inflater,
  lit_dec : HuffmanDecoder,
  dist_dec : HuffmanDecoder,
  dist : Int,
  length : Int,
) -> Decode {
  let dd = self.dd
  let hist_len = dd.hist.length()
  let mut remaining = length
  while remaining > 0 {
    let n = dd.write_copy(dist, remaining)
    remaining -= n
    if dd.wr_pos == hist_len {
      let flushed = self.emit_output()
      if remaining > 0 {
        self.phase = HuffmanMatchCopy(lit_dec, dist_dec, dist, remaining)
        if flushed.length() > 0 {
          return Data(flushed)
        }
        continue
      }
      // Copy complete, resume Huffman loop
      self.phase = HuffmanLoop(lit_dec, dist_dec)
      if flushed.length() > 0 {
        return Data(flushed)
      }
      break
    }
  }
  // Copy complete without filling window, continue Huffman loop
  self.phase = HuffmanLoop(lit_dec, dist_dec)
  self.redispatch = true
  Await
}

///|
fn Inflater::decode_huffman_match_copy(
  self : Inflater,
  lit_dec : HuffmanDecoder,
  dist_dec : HuffmanDecoder,
  dist : Int,
  remaining : Int,
) -> Decode {
  self.do_copy(lit_dec, dist_dec, dist, remaining)
}
