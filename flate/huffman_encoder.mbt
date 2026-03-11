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
  for i in 0..<n {
    if bit_lengths[i] > 0 {
      bl_count[bit_lengths[i]] += 1
    }
  }
  let next_code = FixedArray::make(max_bits + 1, 0)
  let mut code = 0
  for bits in 1..<=max_bits {
    code = (code + bl_count[bits - 1]) << 1
    next_code[bits] = code
  }
  let codes = FixedArray::make(n, 0U)
  for sym in 0..<n {
    let len = bit_lengths[sym]
    if len > 0 {
      let c = next_code[len]
      next_code[len] += 1
      codes[sym] = (reverse_uint(c.reinterpret_as_uint(), len) << 5) |
        len.reinterpret_as_uint()
    }
  }
  { codes, }
}

///|
fn HuffmanCode::get(self : HuffmanCode, sym : Int) -> UInt {
  self.codes[sym]
}

///|
fn HuffmanCode::bit_lengths(self : HuffmanCode) -> FixedArray[Int] {
  let n = self.codes.length()
  let result = FixedArray::make(n, 0)
  for i in 0..<n {
    result[i] = (self.codes[i] & 0x1FU).reinterpret_as_int()
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
  let mut active = 0
  for i in 0..<n {
    if freqs[i] > 0 {
      active += 1
    }
  }
  if active == 0 {
    return bit_lengths
  }
  if active == 1 {
    for i in 0..<n {
      if freqs[i] > 0 {
        bit_lengths[i] = 1
        break
      }
    }
    return bit_lengths
  }
  let sorted = FixedArray::make(active, (0, 0))
  let mut idx = 0
  for i in 0..<n {
    if freqs[i] > 0 {
      sorted[idx] = (freqs[i], i)
      idx += 1
    }
  }
  for i in 1..<active {
    let key = sorted[i]
    let mut j = i - 1
    while j >= 0 && sorted[j].0 > key.0 {
      sorted[j + 1] = sorted[j]
      j -= 1
    }
    sorted[j + 1] = key
  }
  let leaf_freq = FixedArray::make(active, 0)
  let leaf_sym = FixedArray::make(active, 0)
  for i in 0..<active {
    leaf_freq[i] = sorted[i].0
    leaf_sym[i] = sorted[i].1
  }
  let total_nodes = 2 * active - 1
  let parent = FixedArray::make(total_nodes, -1)
  let node_freq = FixedArray::make(total_nodes, 0)
  for i in 0..<active {
    node_freq[i] = leaf_freq[i]
  }
  let mut leaf_ptr = 0
  let mut int_ptr = active
  let mut next_node = active
  for _ in 0..<(active - 1) {
    let left = if leaf_ptr < active &&
      (int_ptr >= next_node || leaf_freq[leaf_ptr] <= node_freq[int_ptr]) {
      let r = leaf_ptr
      leaf_ptr += 1
      r
    } else {
      let r = int_ptr
      int_ptr += 1
      r
    }
    let right = if leaf_ptr < active &&
      (int_ptr >= next_node || leaf_freq[leaf_ptr] <= node_freq[int_ptr]) {
      let r = leaf_ptr
      leaf_ptr += 1
      r
    } else {
      let r = int_ptr
      int_ptr += 1
      r
    }
    node_freq[next_node] = node_freq[left] + node_freq[right]
    parent[left] = next_node
    parent[right] = next_node
    next_node += 1
  }
  let depths = FixedArray::make(total_nodes, 0)
  for i = total_nodes - 1; i >= 0; i = i - 1 {
    if parent[i] >= 0 {
      depths[i] = depths[parent[i]] + 1
    }
  }
  for i in 0..<active {
    bit_lengths[leaf_sym[i]] = depths[i]
  }
  let mut needs_limiting = false
  for i in 0..<n {
    if bit_lengths[i] > max_bits {
      needs_limiting = true
      break
    }
  }
  if needs_limiting {
    for i in 0..<n {
      if bit_lengths[i] > max_bits {
        bit_lengths[i] = max_bits
      }
    }
    let mut kraft = 0
    for i in 0..<n {
      if bit_lengths[i] > 0 {
        kraft += 1 << (max_bits - bit_lengths[i])
      }
    }
    let target = 1 << max_bits
    while kraft > target {
      for len = 1; len < max_bits && kraft > target; len = len + 1 {
        for i in 0..<n {
          if bit_lengths[i] == len && kraft > target {
            bit_lengths[i] += 1
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
  for i in 0..<lit_freqs.length() {
    if lit_freqs[i] > 0 {
      let code_len = if i <= 143 {
        8
      } else if i <= 255 {
        9
      } else if i <= 279 {
        7
      } else {
        8
      }
      total += lit_freqs[i] * code_len
      if i > 256 && i < 286 {
        let length_code_idx = i - 257
        if length_code_idx < length_extra.length() {
          total += lit_freqs[i] * length_extra[length_code_idx]
        }
      }
    }
  }
  for i in 0..<dist_freqs.length() {
    if dist_freqs[i] > 0 {
      total += dist_freqs[i] * 5
      if i < dist_extra.length() {
        total += dist_freqs[i] * dist_extra[i]
      }
    }
  }
  total
}

///|
fn dynamic_block_bit_size(
  lit_freqs : FixedArray[Int],
  dist_freqs : FixedArray[Int],
  lit_codes : HuffmanCode,
  dist_codes : HuffmanCode,
) -> Int {
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
  let mut bits = 3 + 5 + 5 + 4 + 3 * hclen
  let clc = cl_codes.codes
  for i in 0..<19 {
    if cl_freqs[i] > 0 {
      let len = (clc[i] & 0x1FU).reinterpret_as_int()
      bits += cl_freqs[i] * len
      if i == 16 {
        bits += cl_freqs[i] * 2
      } else if i == 17 {
        bits += cl_freqs[i] * 3
      } else if i == 18 {
        bits += cl_freqs[i] * 7
      }
    }
  }
  let lc = lit_codes.codes
  for i in 0..<lit_freqs.length() {
    if lit_freqs[i] > 0 {
      let len = (lc[i] & 0x1FU).reinterpret_as_int()
      bits += lit_freqs[i] * len
      if i > 256 && i < 286 {
        let length_code_idx = i - 257
        if length_code_idx < length_extra.length() {
          bits += lit_freqs[i] * length_extra[length_code_idx]
        }
      }
    }
  }
  let dc = dist_codes.codes
  for i in 0..<dist_freqs.length() {
    if dist_freqs[i] > 0 {
      let len = (dc[i] & 0x1FU).reinterpret_as_int()
      bits += dist_freqs[i] * len
      if i < dist_extra.length() {
        bits += dist_freqs[i] * dist_extra[i]
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
          cl_freqs[18] += 1
          run -= count
        } else if run >= 3 {
          cl_freqs[17] += 1
          run = 0
        } else {
          cl_freqs[0] += 1
          run -= 1
        }
      }
    } else {
      cl_freqs[cur] += 1
      i += 1
      let mut run = 0
      while i + run < total && all[i + run] == cur {
        run += 1
      }
      i += run
      while run > 0 {
        if run >= 3 {
          let count = if run > 6 { 6 } else { run }
          cl_freqs[16] += 1
          run -= count
        } else {
          cl_freqs[cur] += 1
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
