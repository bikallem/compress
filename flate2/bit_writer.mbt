///|
/// Bit writer that accumulates compressed output in a FixedArray buffer.
/// When the buffer is full, bytes are collected for emission via Deflater.
priv struct BitWriter {
  mut buf : FixedArray[Byte]
  mut pos : Int
  mut bits : UInt64
  mut n_bits : Int
}

///|
fn BitWriter::new(size_hint? : Int = 8192) -> BitWriter {
  let cap = if size_hint > 256 { size_hint } else { 256 }
  { buf: FixedArray::make(cap, b'\x00'), pos: 0, bits: 0UL, n_bits: 0 }
}

///|
fn BitWriter::ensure_capacity(self : BitWriter, needed : Int) -> Unit {
  if self.pos + needed > self.buf.length() {
    let new_cap = if self.buf.length() * 2 > self.pos + needed {
      self.buf.length() * 2
    } else {
      self.pos + needed
    }
    let new_buf = FixedArray::make(new_cap, b'\x00')
    @blit.blit_fixed_array(new_buf, 0, self.buf, 0, self.pos)
    self.buf = new_buf
  }
}

///|
fn BitWriter::write_bits_lsb(self : BitWriter, val : UInt, n : Int) -> Unit {
  self.bits = self.bits | (val.to_uint64() << self.n_bits)
  self.n_bits += n
  while self.n_bits >= 8 {
    if self.pos == self.buf.length() {
      self.ensure_capacity(1)
    }
    self.buf.unsafe_set(self.pos, (self.bits & 0xFFUL).to_byte())
    self.pos += 1
    self.bits = self.bits >> 8
    self.n_bits -= 8
  }
}

///|
fn BitWriter::start_fixed_block(self : BitWriter, is_final : Bool) -> Unit {
  let header = if is_final { 0b011U } else { 0b010U }
  self.write_bits_lsb(header, 3)
}

///|
fn BitWriter::write_literal_fast(self : BitWriter, b : Byte) -> Unit {
  let entry = fixed_lit_codes.unsafe_get(b.to_int())
  self.write_bits_lsb(entry >> 4, (entry & 0xFU).reinterpret_as_int())
}

///|
fn BitWriter::write_fixed_symbol(self : BitWriter, sym : Int) -> Unit {
  let entry = fixed_lit_codes.unsafe_get(sym)
  self.write_bits_lsb(entry >> 4, (entry & 0xFU).reinterpret_as_int())
}

///|
fn BitWriter::write_match_fast(
  self : BitWriter,
  length : Int,
  offset : Int,
) -> Unit {
  let lidx = (length - MIN_MATCH_LENGTH) * 3
  let length_code = length_encode_table.unsafe_get(lidx)
  let length_extra_bits = length_encode_table.unsafe_get(lidx + 1)
  let length_extra_val = length_encode_table.unsafe_get(lidx + 2)
  let lentry = fixed_lit_codes.unsafe_get(length_code)
  self.write_bits_lsb(lentry >> 4, (lentry & 0xFU).reinterpret_as_int())
  if length_extra_bits > 0 {
    self.write_bits_lsb(
      length_extra_val.reinterpret_as_uint(), length_extra_bits,
    )
  }
  let didx = (offset - 1) * 2
  let dist_code = dist_encode_table.unsafe_get(didx)
  let dist_extra_bits = dist_encode_table.unsafe_get(didx + 1)
  let dist_extra_val = offset - dist_base.unsafe_get(dist_code)
  self.write_bits_lsb(fixed_dist_codes.unsafe_get(dist_code), 5)
  if dist_extra_bits > 0 {
    self.write_bits_lsb(dist_extra_val.reinterpret_as_uint(), dist_extra_bits)
  }
}

///|
fn BitWriter::write_stored_header(
  self : BitWriter,
  len : Int,
  is_final : Bool,
) -> Unit {
  let header = if is_final { 0b001U } else { 0b000U }
  self.write_bits_lsb(header, 3)
  if self.n_bits > 0 {
    if self.pos == self.buf.length() {
      self.ensure_capacity(1)
    }
    self.buf.unsafe_set(self.pos, (self.bits & 0xFFUL).to_byte())
    self.pos += 1
    self.bits = 0UL
    self.n_bits = 0
  }
  self.ensure_capacity(4)
  self.buf.unsafe_set(self.pos, (len & 0xFF).to_byte())
  self.pos += 1
  self.buf.unsafe_set(self.pos, (len >> 8).to_byte())
  self.pos += 1
  let nlen = len ^ 0xFFFF
  self.buf.unsafe_set(self.pos, (nlen & 0xFF).to_byte())
  self.pos += 1
  self.buf.unsafe_set(self.pos, (nlen >> 8).to_byte())
  self.pos += 1
}

///|
fn BitWriter::write_stored_data(
  self : BitWriter,
  data : FixedArray[Byte],
  offset : Int,
  len : Int,
) -> Unit {
  self.ensure_capacity(len)
  @blit.blit_fixed_array(self.buf, self.pos, data, offset, len)
  self.pos += len
}

///|
fn BitWriter::write_dynamic_block(
  self : BitWriter,
  tokens : Array[Token],
  is_final : Bool,
) -> Unit {
  let lit_freqs = FixedArray::make(286, 0)
  let dist_freqs = FixedArray::make(30, 0)
  for t in tokens {
    if t.is_match() {
      let lidx = (t.get_length() - MIN_MATCH_LENGTH) * 3
      lit_freqs[length_encode_table[lidx]] += 1
      dist_freqs[dist_encode_table[(t.get_dist() - 1) * 2]] += 1
    } else {
      lit_freqs[t.get_literal().to_int()] += 1
    }
  }
  lit_freqs[END_BLOCK_MARKER] += 1
  if dist_freqs[0] == 0 {
    let mut has_dist = false
    for i in 0..<30 {
      if dist_freqs[i] > 0 {
        has_dist = true
        break
      }
    }
    if not(has_dist) {
      dist_freqs[0] = 1
    }
  }
  let dyn_lit_codes = HuffmanCode::from_freqs(lit_freqs, 15)
  let dyn_dist_codes = HuffmanCode::from_freqs(dist_freqs, 15)
  let fixed_size = fixed_block_bit_size(lit_freqs, dist_freqs)
  let dynamic_size = dynamic_block_bit_size(
    lit_freqs, dist_freqs, dyn_lit_codes, dyn_dist_codes,
  )
  if fixed_size <= dynamic_size {
    self.start_fixed_block(is_final)
    for t in tokens {
      if t.is_match() {
        self.write_match_fast(t.get_length(), t.get_dist())
      } else {
        self.write_literal_fast(t.get_literal())
      }
    }
    self.write_fixed_symbol(END_BLOCK_MARKER)
  } else {
    self.write_dynamic_header(dyn_lit_codes, dyn_dist_codes, is_final)
    for t in tokens {
      if t.is_match() {
        let length = t.get_length()
        let dist = t.get_dist()
        let lidx = (length - MIN_MATCH_LENGTH) * 3
        let length_code = length_encode_table[lidx]
        let length_extra_bits = length_encode_table[lidx + 1]
        let length_extra_val = length_encode_table[lidx + 2]
        let lentry = dyn_lit_codes.get(length_code)
        self.write_bits_lsb(lentry >> 5, (lentry & 0x1FU).reinterpret_as_int())
        if length_extra_bits > 0 {
          self.write_bits_lsb(
            length_extra_val.reinterpret_as_uint(), length_extra_bits,
          )
        }
        let didx = (dist - 1) * 2
        let dist_code = dist_encode_table[didx]
        let dist_extra_bits = dist_encode_table[didx + 1]
        let dist_extra_val = dist - dist_base[dist_code]
        let dentry = dyn_dist_codes.get(dist_code)
        self.write_bits_lsb(dentry >> 5, (dentry & 0x1FU).reinterpret_as_int())
        if dist_extra_bits > 0 {
          self.write_bits_lsb(
            dist_extra_val.reinterpret_as_uint(), dist_extra_bits,
          )
        }
      } else {
        let entry = dyn_lit_codes.get(t.get_literal().to_int())
        self.write_bits_lsb(entry >> 5, (entry & 0x1FU).reinterpret_as_int())
      }
    }
    let eob = dyn_lit_codes.get(END_BLOCK_MARKER)
    self.write_bits_lsb(eob >> 5, (eob & 0x1FU).reinterpret_as_int())
  }
}

///|
fn BitWriter::write_dynamic_header(
  self : BitWriter,
  lit_codes : HuffmanCode,
  dist_codes : HuffmanCode,
  is_final : Bool,
) -> Unit {
  let header = if is_final { 0b101U } else { 0b100U }
  self.write_bits_lsb(header, 3)
  let lit_bl = lit_codes.bit_lengths()
  let dist_bl = dist_codes.bit_lengths()
  let mut hlit = 286
  while hlit > 257 && lit_bl[hlit - 1] == 0 {
    hlit -= 1
  }
  let mut hdist = 30
  while hdist > 1 && dist_bl[hdist - 1] == 0 {
    hdist -= 1
  }
  let cl_freqs = FixedArray::make(19, 0)
  rle_count_freqs(lit_bl, hlit, dist_bl, hdist, cl_freqs)
  let cl_codes = HuffmanCode::from_freqs(cl_freqs, 7)
  let cl_bl = cl_codes.bit_lengths()
  let mut hclen = 19
  while hclen > 4 && cl_bl[code_order[hclen - 1]] == 0 {
    hclen -= 1
  }
  self.write_bits_lsb((hlit - 257).reinterpret_as_uint(), 5)
  self.write_bits_lsb((hdist - 1).reinterpret_as_uint(), 5)
  self.write_bits_lsb((hclen - 4).reinterpret_as_uint(), 4)
  for i in 0..<hclen {
    self.write_bits_lsb(cl_bl[code_order[i]].reinterpret_as_uint(), 3)
  }
  let total = hlit + hdist
  let all = FixedArray::make(total, 0)
  for i in 0..<hlit {
    all[i] = lit_bl[i]
  }
  for i in 0..<hdist {
    all[hlit + i] = dist_bl[i]
  }
  let mut i = 0
  while i < total {
    let cur = all[i]
    if cur == 0 {
      let mut run = 1
      while i + run < total && all[i + run] == 0 {
        run += 1
      }
      i += run
      while run > 0 {
        if run >= 11 {
          let count = if run > 138 { 138 } else { run }
          let entry = cl_codes.get(18)
          self.write_bits_lsb(entry >> 5, (entry & 0x1FU).reinterpret_as_int())
          self.write_bits_lsb((count - 11).reinterpret_as_uint(), 7)
          run -= count
        } else if run >= 3 {
          let entry = cl_codes.get(17)
          self.write_bits_lsb(entry >> 5, (entry & 0x1FU).reinterpret_as_int())
          self.write_bits_lsb((run - 3).reinterpret_as_uint(), 3)
          run = 0
        } else {
          let entry = cl_codes.get(0)
          self.write_bits_lsb(entry >> 5, (entry & 0x1FU).reinterpret_as_int())
          run -= 1
        }
      }
    } else {
      let entry = cl_codes.get(cur)
      self.write_bits_lsb(entry >> 5, (entry & 0x1FU).reinterpret_as_int())
      i += 1
      let mut run = 0
      while i + run < total && all[i + run] == cur {
        run += 1
      }
      i += run
      while run > 0 {
        if run >= 3 {
          let count = if run > 6 { 6 } else { run }
          let entry = cl_codes.get(16)
          self.write_bits_lsb(entry >> 5, (entry & 0x1FU).reinterpret_as_int())
          self.write_bits_lsb((count - 3).reinterpret_as_uint(), 2)
          run -= count
        } else {
          let entry = cl_codes.get(cur)
          self.write_bits_lsb(entry >> 5, (entry & 0x1FU).reinterpret_as_int())
          run -= 1
        }
      }
    }
  }
}

///|
/// Extract all accumulated bytes and reset.
fn BitWriter::take_output(self : BitWriter) -> Bytes {
  if self.n_bits > 0 {
    if self.pos == self.buf.length() {
      self.ensure_capacity(1)
    }
    self.buf.unsafe_set(self.pos, (self.bits & 0xFFUL).to_byte())
    self.pos += 1
    self.bits = 0UL
    self.n_bits = 0
  }
  if self.pos == 0 {
    return Bytes::default()
  }
  let result = @blit.make_uninit(self.pos)
  @blit.blit_fixed_array(result, 0, self.buf, 0, self.pos)
  self.pos = 0
  result.unsafe_reinterpret_as_bytes()
}

///|
/// Finalize: flush remaining bits, return final output.
fn BitWriter::finish(self : BitWriter) -> Bytes {
  self.take_output()
}
