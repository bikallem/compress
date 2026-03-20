///|
/// Huffman code for encoding: stores reversed code and bit length.
/// Entry format: (reversed_code << 5) | code_length
priv struct HuffmanCode {
  codes : FixedArray[UInt]
}

///|
fn HuffmanCode::from_freqs(
  freqs : FixedArray[Int],
  max_bits : Int,
) -> HuffmanCode {
  let n = freqs.length()
  let bit_lengths = compute_bit_lengths(freqs, max_bits)
  let bl_count = FixedArray::make(max_bits + 1, 0)
  for _, bl in bit_lengths {
    if bl > 0 {
      bl_count.unsafe_set(bl, bl_count.unsafe_get(bl) + 1)
    }
  }
  let next_code = FixedArray::make(max_bits + 1, 0)
  for bits = 1, code = 0; bits <= max_bits; {
    let c = (code + bl_count.unsafe_get(bits - 1)) << 1
    next_code.unsafe_set(bits, c)
    continue bits + 1, c
  }
  let codes = FixedArray::make(n, 0U)
  for sym, len in bit_lengths {
    if len > 0 {
      let c = next_code.unsafe_get(len)
      next_code.unsafe_set(len, c + 1)
      codes.unsafe_set(sym, (reverse_uint(c.reinterpret_as_uint(), len) << 5) |
        len.reinterpret_as_uint())
    }
  }
  { codes, }
}

///|
fn HuffmanCode::get(self : HuffmanCode, sym : Int) -> UInt {
  self.codes.unsafe_get(sym)
}

///|
fn HuffmanCode::bit_lengths(self : HuffmanCode) -> FixedArray[Int] {
  let result = FixedArray::make(self.codes.length(), 0)
  for i, code in self.codes {
    result.unsafe_set(i, (code & 0x1FU).reinterpret_as_int())
  }
  result
}

///|
fn compute_bit_lengths(
  freqs : FixedArray[Int],
  max_bits : Int,
) -> FixedArray[Int] {
  let n = freqs.length()
  let bit_lengths = FixedArray::make(n, 0)
  let active = for i = 0, active = 0; i < n; i = i + 1 {
    continue i + 1, active + (if freqs.unsafe_get(i) > 0 { 1 } else { 0 })
  } nobreak {
    active
  }
  if active == 0 {
    return bit_lengths
  }
  if active == 1 {
    for i in 0..<n {
      if freqs.unsafe_get(i) > 0 {
        bit_lengths.unsafe_set(i, 1)
        break
      }
    }
    return bit_lengths
  }
  // Use parallel arrays instead of tuple array for better cache locality
  let leaf_freq = @blit.make_uninit_int(active)
  let leaf_sym = @blit.make_uninit_int(active)
  for i = 0, idx = 0; i < n; {
    if freqs.unsafe_get(i) > 0 {
      leaf_freq.unsafe_set(idx, freqs.unsafe_get(i))
      leaf_sym.unsafe_set(idx, i)
      continue i + 1, idx + 1
    }
    continue i + 1, idx
  }
  // Insertion sort by frequency (parallel arrays)
  for i in 1..<active {
    let kf = leaf_freq.unsafe_get(i)
    let ks = leaf_sym.unsafe_get(i)
    let mut j = i - 1
    while j >= 0 && leaf_freq.unsafe_get(j) > kf {
      leaf_freq.unsafe_set(j + 1, leaf_freq.unsafe_get(j))
      leaf_sym.unsafe_set(j + 1, leaf_sym.unsafe_get(j))
      j -= 1
    }
    leaf_freq.unsafe_set(j + 1, kf)
    leaf_sym.unsafe_set(j + 1, ks)
  }
  let total_nodes = 2 * active - 1
  let parent = FixedArray::make(total_nodes, -1)
  let node_freq = @blit.make_uninit_int(total_nodes)
  for i in 0..<active {
    node_freq.unsafe_set(i, leaf_freq.unsafe_get(i))
  }
  let mut leaf_ptr = 0
  let mut int_ptr = active
  let mut next_node = active
  for _ in 0..<(active - 1) {
    let left = if leaf_ptr < active &&
      (int_ptr >= next_node || leaf_freq.unsafe_get(leaf_ptr) <= node_freq.unsafe_get(int_ptr)) {
      let r = leaf_ptr
      leaf_ptr += 1
      r
    } else {
      let r = int_ptr
      int_ptr += 1
      r
    }
    let right = if leaf_ptr < active &&
      (int_ptr >= next_node || leaf_freq.unsafe_get(leaf_ptr) <= node_freq.unsafe_get(int_ptr)) {
      let r = leaf_ptr
      leaf_ptr += 1
      r
    } else {
      let r = int_ptr
      int_ptr += 1
      r
    }
    node_freq.unsafe_set(next_node, node_freq.unsafe_get(left) + node_freq.unsafe_get(right))
    parent.unsafe_set(left, next_node)
    parent.unsafe_set(right, next_node)
    next_node += 1
  }
  let depths = FixedArray::make(total_nodes, 0)
  for i = total_nodes - 1; i >= 0; i = i - 1 {
    let p = parent.unsafe_get(i)
    if p >= 0 {
      depths.unsafe_set(i, depths.unsafe_get(p) + 1)
    }
  }
  for i, sym in leaf_sym {
    bit_lengths.unsafe_set(sym, depths.unsafe_get(i))
  }
  let mut needs_limiting = false
  for i in 0..<n {
    if bit_lengths.unsafe_get(i) > max_bits {
      needs_limiting = true
      break
    }
  }
  if needs_limiting {
    for i in 0..<n {
      if bit_lengths.unsafe_get(i) > max_bits {
        bit_lengths.unsafe_set(i, max_bits)
      }
    }
    let mut kraft = for i = 0, kraft = 0; i < n; i = i + 1 {
      let bl = bit_lengths.unsafe_get(i)
      continue i + 1,
        kraft +
        (if bl > 0 { 1 << (max_bits - bl) } else { 0 })
    } nobreak {
      kraft
    }
    let target = 1 << max_bits
    while kraft > target {
      for len = 1; len < max_bits && kraft > target; len = len + 1 {
        for i in 0..<n {
          if bit_lengths.unsafe_get(i) == len && kraft > target {
            bit_lengths.unsafe_set(i, len + 1)
            kraft -= 1 << (max_bits - len - 1)
          }
        }
      }
    }
  }
  bit_lengths
}

///|
#valtype
priv struct Token {
  bits : Int64
}

///|
fn Token::literal(b : Byte) -> Token {
  { bits: b.to_int().to_int64() }
}

///|
fn Token::match_(length : Int, dist : Int) -> Token {
  let bits = (1L << 63) | (dist.to_int64() << 16) | length.to_int64()
  { bits, }
}

///|
fn Token::is_match(self : Token) -> Bool {
  self.bits < 0L
}

///|
fn Token::get_literal(self : Token) -> Byte {
  (self.bits & 0xFFL).to_byte()
}

///|
fn Token::get_length(self : Token) -> Int {
  (self.bits & 0xFFFFL).to_int()
}

///|
fn Token::get_dist(self : Token) -> Int {
  ((self.bits >> 16) & 0xFFFFL).to_int()
}

///|
fn fixed_block_bit_size(
  lit_freqs : FixedArray[Int],
  dist_freqs : FixedArray[Int],
) -> Int {
  let mut total = 3
  for i, freq in lit_freqs {
    if freq > 0 {
      let code_len = match i {
        0..=143 => 8
        144..=255 => 9
        256..=279 => 7
        _ => 8
      }
      total += freq * code_len
      if i > 256 && i < 286 {
        let length_code_idx = i - 257
        if length_code_idx < length_extra.length() {
          total += freq * length_extra.unsafe_get(length_code_idx)
        }
      }
    }
  }
  for i, freq in dist_freqs {
    if freq > 0 {
      total += freq * 5
      if i < dist_extra.length() {
        total += freq * dist_extra.unsafe_get(i)
      }
    }
  }
  total
}

///|
/// Compute dynamic block size using precomputed code-length tree data.
fn compute_dynamic_block_size(
  lit_freqs : FixedArray[Int],
  dist_freqs : FixedArray[Int],
  lit_codes : HuffmanCode,
  dist_codes : HuffmanCode,
  cl_freqs : FixedArray[Int],
  cl_codes : HuffmanCode,
  hclen : Int,
) -> Int {
  let mut bits = 3 + 5 + 5 + 4 + 3 * hclen
  let clc = cl_codes.codes
  for i in 0..<19 {
    let clf = cl_freqs.unsafe_get(i)
    if clf > 0 {
      let len = (clc.unsafe_get(i) & 0x1FU).reinterpret_as_int()
      bits += clf * len
      if i == CL_REPEAT_PREV {
        bits += clf * 2
      } else if i == CL_REPEAT_ZERO_SHORT {
        bits += clf * 3
      } else if i == CL_REPEAT_ZERO_LONG {
        bits += clf * 7
      }
    }
  }
  let lc = lit_codes.codes
  for i, freq in lit_freqs {
    if freq > 0 {
      let len = (lc.unsafe_get(i) & 0x1FU).reinterpret_as_int()
      bits += freq * len
      if i > 256 && i < 286 {
        let length_code_idx = i - 257
        if length_code_idx < length_extra.length() {
          bits += freq * length_extra.unsafe_get(length_code_idx)
        }
      }
    }
  }
  let dc = dist_codes.codes
  for i, freq in dist_freqs {
    if freq > 0 {
      let len = (dc.unsafe_get(i) & 0x1FU).reinterpret_as_int()
      bits += freq * len
      if i < dist_extra.length() {
        bits += freq * dist_extra.unsafe_get(i)
      }
    }
  }
  bits
}

///|
fn rle_count_freqs(
  lit_bl : FixedArray[Int],
  hlit : Int,
  dist_bl : FixedArray[Int],
  hdist : Int,
  cl_freqs : FixedArray[Int],
) -> Unit {
  let total = hlit + hdist
  let all = @blit.make_uninit_int(total)
  for i in 0..<hlit {
    all.unsafe_set(i, lit_bl.unsafe_get(i))
  }
  for i in 0..<hdist {
    all.unsafe_set(hlit + i, dist_bl.unsafe_get(i))
  }
  let mut i = 0
  while i < total {
    let cur = all.unsafe_get(i)
    if cur == 0 {
      let mut run = 1
      while i + run < total && all.unsafe_get(i + run) == 0 {
        run += 1
      }
      i += run
      while run > 0 {
        if run >= 11 {
          let count = if run > 138 { 138 } else { run }
          cl_freqs.unsafe_set(CL_REPEAT_ZERO_LONG, cl_freqs.unsafe_get(CL_REPEAT_ZERO_LONG) + 1)
          run -= count
        } else if run >= 3 {
          cl_freqs.unsafe_set(CL_REPEAT_ZERO_SHORT, cl_freqs.unsafe_get(CL_REPEAT_ZERO_SHORT) + 1)
          run = 0
        } else {
          cl_freqs.unsafe_set(0, cl_freqs.unsafe_get(0) + 1)
          run -= 1
        }
      }
    } else {
      cl_freqs.unsafe_set(cur, cl_freqs.unsafe_get(cur) + 1)
      i += 1
      let mut run = 0
      while i + run < total && all.unsafe_get(i + run) == cur {
        run += 1
      }
      i += run
      while run > 0 {
        if run >= 3 {
          let count = if run > 6 { 6 } else { run }
          cl_freqs.unsafe_set(CL_REPEAT_PREV, cl_freqs.unsafe_get(CL_REPEAT_PREV) + 1)
          run -= count
        } else {
          cl_freqs.unsafe_set(cur, cl_freqs.unsafe_get(cur) + 1)
          run -= 1
        }
      }
    }
  }
}

///|
fn reverse_uint(val : UInt, n : Int) -> UInt {
  let (result, _) = for result = 0U, v = val, i = 0; i < n; {
    continue (result << 1) | (v & 1U), v >> 1, i + 1
  } nobreak {
    (result, val)
  }
  result
}
