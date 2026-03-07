///|
/// Huffman code for encoding: stores reversed code and bit length.
/// Entry format: (reversed_code << 5) | code_length
priv struct HuffmanCode {
  codes : FixedArray[UInt]
}

///|
/// Build canonical Huffman codes from frequency counts.
fn HuffmanCode::from_freqs(
  freqs : FixedArray[Int],
  max_bits : Int,
) -> HuffmanCode {
  let n = freqs.length()
  let bit_lengths = compute_bit_lengths(freqs, max_bits)
  // Build canonical codes per RFC 1951 section 3.2.2
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
/// Compute optimal bit lengths using a Huffman tree.
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
  // Build sorted list of (freq, symbol) pairs
  let sorted = FixedArray::make(active, (0, 0))
  let mut idx = 0
  for i in 0..<n {
    if freqs[i] > 0 {
      sorted[idx] = (freqs[i], i)
      idx += 1
    }
  }
  // Sort by frequency (insertion sort)
  for i in 1..<active {
    let key = sorted[i]
    let mut j = i - 1
    while j >= 0 && sorted[j].0 > key.0 {
      sorted[j + 1] = sorted[j]
      j -= 1
    }
    sorted[j + 1] = key
  }
  // Build Huffman tree using two-queue approach
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
    // Pick smallest from leaf or internal queue
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
  // Compute depths from parent pointers
  let depths = FixedArray::make(total_nodes, 0)
  for i = total_nodes - 1; i >= 0; i = i - 1 {
    if parent[i] >= 0 {
      depths[i] = depths[parent[i]] + 1
    }
  }
  for i in 0..<active {
    bit_lengths[leaf_sym[i]] = depths[i]
  }
  // Limit bit lengths to max_bits
  let mut needs_limiting = false
  for i in 0..<n {
    if bit_lengths[i] > max_bits {
      needs_limiting = true
      break
    }
  }
  if needs_limiting {
    // Clamp all to max_bits and rebuild to satisfy Kraft inequality
    for i in 0..<n {
      if bit_lengths[i] > max_bits {
        bit_lengths[i] = max_bits
      }
    }
    // Verify and fix Kraft inequality
    let mut kraft = 0
    for i in 0..<n {
      if bit_lengths[i] > 0 {
        kraft += 1 << (max_bits - bit_lengths[i])
      }
    }
    let target = 1 << max_bits
    // If over budget, increase some short codes
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
/// LZ77 token: either a literal byte or a length/distance match.
priv enum Token {
  Literal(Byte)
  Match(length~ : Int, dist~ : Int)
}

///|
/// Collect frequency counts and calculate block size for fixed Huffman.
fn fixed_block_bit_size(
  lit_freqs : FixedArray[Int],
  dist_freqs : FixedArray[Int],
) -> Int {
  let mut total = 3 // block header
  for i in 0..<lit_freqs.length() {
    if lit_freqs[i] > 0 {
      // Fixed Huffman code lengths
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
      total += dist_freqs[i] * 5 // fixed distance is always 5 bits
      if i < dist_extra.length() {
        total += dist_freqs[i] * dist_extra[i]
      }
    }
  }
  total
}

///|
/// Calculate dynamic block size (header + encoded data).
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
  // Count code length symbol frequencies
  let cl_freqs = FixedArray::make(19, 0)
  rle_count_freqs(lit_bl, hlit, dist_bl, hdist, cl_freqs)
  let cl_codes = HuffmanCode::from_freqs(cl_freqs, 7)
  let cl_bl = cl_codes.bit_lengths()
  let mut hclen = 19
  while hclen > 4 && cl_bl[code_order[hclen - 1]] == 0 {
    hclen -= 1
  }
  // Header bits
  let mut bits = 3 + 5 + 5 + 4 + 3 * hclen
  // Code length encoding bits
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
  // Data bits
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
/// Count code length symbol frequencies from RLE encoding.
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
          run -= run // consume all remaining (3-10)
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
/// Write the dynamic Huffman block header and encode tokens.
fn DeflateWriter::write_dynamic_block(
  self : DeflateWriter,
  tokens : Array[Token],
  is_final : Bool,
) -> Unit {
  // Count frequencies
  let lit_freqs = FixedArray::make(286, 0)
  let dist_freqs = FixedArray::make(30, 0)
  for t in tokens {
    match t {
      Literal(b) => lit_freqs[b.to_int()] += 1
      Match(length~, dist~) => {
        let lidx = (length - MIN_MATCH_LENGTH) * 3
        let length_code = length_encode_table[lidx]
        lit_freqs[length_code] += 1
        let didx = (dist - 1) * 2
        let dist_code = dist_encode_table[didx]
        dist_freqs[dist_code] += 1
      }
    }
  }
  lit_freqs[END_BLOCK_MARKER] += 1
  // Ensure at least one distance code exists
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
  // Build optimal Huffman codes
  let dyn_lit_codes = HuffmanCode::from_freqs(lit_freqs, 15)
  let dyn_dist_codes = HuffmanCode::from_freqs(dist_freqs, 15)
  // Compare fixed vs dynamic size
  let fixed_size = fixed_block_bit_size(lit_freqs, dist_freqs)
  let dynamic_size = dynamic_block_bit_size(
    lit_freqs, dist_freqs, dyn_lit_codes, dyn_dist_codes,
  )
  if fixed_size <= dynamic_size {
    // Use fixed Huffman
    self.start_fixed_block(is_final)
    for t in tokens {
      match t {
        Literal(b) => self.write_literal_fast(b)
        Match(length~, dist~) => self.write_match_fast(length, dist)
      }
    }
    self.write_fixed_symbol(END_BLOCK_MARKER)
  } else {
    // Use dynamic Huffman
    self.write_dynamic_header(dyn_lit_codes, dyn_dist_codes, is_final)
    for t in tokens {
      match t {
        Literal(b) => {
          let entry = dyn_lit_codes.get(b.to_int())
          let code = entry >> 5
          let n = (entry & 0x1FU).reinterpret_as_int()
          self.write_bits_lsb(code, n)
        }
        Match(length~, dist~) => {
          // Length code
          let lidx = (length - MIN_MATCH_LENGTH) * 3
          let length_code = length_encode_table[lidx]
          let length_extra_bits = length_encode_table[lidx + 1]
          let length_extra_val = length_encode_table[lidx + 2]
          let lentry = dyn_lit_codes.get(length_code)
          let lcode = lentry >> 5
          let ln = (lentry & 0x1FU).reinterpret_as_int()
          self.write_bits_lsb(lcode, ln)
          if length_extra_bits > 0 {
            self.write_bits_lsb(
              length_extra_val.reinterpret_as_uint(),
              length_extra_bits,
            )
          }
          // Distance code
          let didx = (dist - 1) * 2
          let dist_code = dist_encode_table[didx]
          let dist_extra_bits = dist_encode_table[didx + 1]
          let dist_extra_val = dist - dist_base[dist_code]
          let dentry = dyn_dist_codes.get(dist_code)
          let dcode = dentry >> 5
          let dn = (dentry & 0x1FU).reinterpret_as_int()
          self.write_bits_lsb(dcode, dn)
          if dist_extra_bits > 0 {
            self.write_bits_lsb(
              dist_extra_val.reinterpret_as_uint(),
              dist_extra_bits,
            )
          }
        }
      }
    }
    // End of block
    let eob = dyn_lit_codes.get(END_BLOCK_MARKER)
    let eob_code = eob >> 5
    let eob_n = (eob & 0x1FU).reinterpret_as_int()
    self.write_bits_lsb(eob_code, eob_n)
  }
}

///|
/// Write the dynamic Huffman block header (HLIT, HDIST, HCLEN, code lengths).
fn DeflateWriter::write_dynamic_header(
  self : DeflateWriter,
  lit_codes : HuffmanCode,
  dist_codes : HuffmanCode,
  is_final : Bool,
) -> Unit {
  let header = if is_final { 0b101U } else { 0b100U }
  self.write_bits_lsb(header, 3) // BFINAL + BTYPE=10
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
  // Count code length frequencies
  let cl_freqs = FixedArray::make(19, 0)
  rle_count_freqs(lit_bl, hlit, dist_bl, hdist, cl_freqs)
  let cl_codes = HuffmanCode::from_freqs(cl_freqs, 7)
  let cl_bl = cl_codes.bit_lengths()
  let mut hclen = 19
  while hclen > 4 && cl_bl[code_order[hclen - 1]] == 0 {
    hclen -= 1
  }
  // Write HLIT, HDIST, HCLEN
  self.write_bits_lsb((hlit - 257).reinterpret_as_uint(), 5)
  self.write_bits_lsb((hdist - 1).reinterpret_as_uint(), 5)
  self.write_bits_lsb((hclen - 4).reinterpret_as_uint(), 4)
  // Write code length code lengths in code_order
  for i in 0..<hclen {
    self.write_bits_lsb(cl_bl[code_order[i]].reinterpret_as_uint(), 3)
  }
  // RLE encode and write the code lengths
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
