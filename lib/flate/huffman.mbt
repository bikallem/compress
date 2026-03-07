///|
/// HuffmanDecoder decodes Huffman-encoded symbols from a bit stream.
/// Uses a two-level table lookup for fast decoding.
priv struct HuffmanDecoder {
  // First-level table: indexed by low bits of code
  // Entry format: (symbol << 8) | code_length for codes <= chunk_bits
  // Or (link_index << 8) | chunk_bits for longer codes
  chunks : FixedArray[UInt]
  // Second-level tables for codes longer than chunk_bits
  links : Array[FixedArray[UInt]]
  min_bits : Int
  max_bits : Int
}

///|
let huffman_chunk_bits : Int = 9

///|
/// Builds a Huffman decoder from code lengths.
/// `lengths` maps symbol -> bit length (0 means unused).
fn HuffmanDecoder::build(
  lengths : FixedArray[Int],
) -> HuffmanDecoder raise CompressError {
  // Count codes of each length
  let count = FixedArray::make(max_code_len + 1, 0)
  let mut min_bits = max_code_len
  let mut max_bits = 0
  for i in 0..<lengths.length() {
    let n = lengths[i]
    if n > 0 {
      count[n] += 1
      if n < min_bits {
        min_bits = n
      }
      if n > max_bits {
        max_bits = n
      }
    }
  }
  if max_bits == 0 {
    raise CompressError::CorruptInput("empty Huffman tree")
  }
  // Compute next_code[] per RFC 1951 section 3.2.2
  let next_code = FixedArray::make(max_code_len + 1, 0)
  let mut code = 0
  for bits in 1..<=max_bits {
    code = (code + count[bits - 1]) << 1
    next_code[bits] = code
  }
  // Build chunks table
  let chunk_size = 1 << huffman_chunk_bits
  let chunks = FixedArray::make(chunk_size, 0U)
  let links : Array[FixedArray[UInt]] = []
  // Assign codes and populate lookup tables
  for sym in 0..<lengths.length() {
    let n = lengths[sym]
    if n == 0 {
      continue
    }
    let c = next_code[n]
    next_code[n] += 1
    // Reverse the bits for LSB-first lookup
    let reversed = reverse_bits(c, n)
    if n <= huffman_chunk_bits {
      // Direct entry in chunks table
      let entry = (sym.reinterpret_as_uint() << 8) | n.reinterpret_as_uint()
      // Fill all chunk entries that share this prefix
      let step = 1 << n
      let mut idx = reversed
      while idx < chunk_size {
        chunks[idx] = entry
        idx += step
      }
    } else {
      // Longer code: need link table
      let prefix = reversed & ((1 << huffman_chunk_bits) - 1)
      if chunks[prefix] == 0U {
        // Create link table entry
        let link_idx = links.length()
        let link_bits = max_bits - huffman_chunk_bits
        let link_size = 1 << link_bits
        links.push(FixedArray::make(link_size, 0U))
        chunks[prefix] = (link_idx.reinterpret_as_uint() << 8) |
          ((huffman_chunk_bits + link_bits).reinterpret_as_uint() | 0x80U)
      }
      let link_info = chunks[prefix]
      let link_idx = (link_info >> 8).reinterpret_as_int()
      let link_table = links[link_idx]
      let suffix = reversed >> huffman_chunk_bits
      let link_bits = max_bits - huffman_chunk_bits
      let entry = (sym.reinterpret_as_uint() << 8) | n.reinterpret_as_uint()
      let step = 1 << (n - huffman_chunk_bits)
      let mut idx = suffix
      while idx < 1 << link_bits {
        link_table[idx] = entry
        idx += step
      }
    }
  }
  { chunks, links, min_bits, max_bits }
}

///|
/// Reverses the lowest `n` bits of `val`.
fn reverse_bits(val : Int, n : Int) -> Int {
  let mut result = 0
  let mut v = val
  for _ in 0..<n {
    result = (result << 1) | (v & 1)
    v = v >> 1
  }
  result
}

///|
/// Decodes a single symbol from the bit stream.
fn HuffmanDecoder::decode(
  self : HuffmanDecoder,
  bit_buf : Ref[UInt64],
  bit_count : Ref[Int],
  data : Bytes,
  pos : Ref[Int],
) -> Int raise CompressError {
  // Ensure enough bits
  while bit_count.val < self.max_bits {
    if pos.val >= data.length() {
      if bit_count.val >= self.min_bits {
        break
      }
      raise CompressError::UnexpectedEOF
    }
    bit_buf.val = bit_buf.val | (data[pos.val].to_uint64() << bit_count.val)
    bit_count.val += 8
    pos.val += 1
  }
  // Look up in chunks table
  let idx = (bit_buf.val & ((1UL << huffman_chunk_bits) - 1UL)).to_int()
  let entry = self.chunks[idx]
  if (entry & 0x80U) == 0U {
    // Direct hit
    let n = (entry & 0xFFU).reinterpret_as_int()
    let sym = (entry >> 8).reinterpret_as_int()
    bit_buf.val = bit_buf.val >> n
    bit_count.val -= n
    return sym
  }
  // Need link table
  let link_idx = (entry >> 8).reinterpret_as_int()
  let link_table = self.links[link_idx]
  let suffix = (bit_buf.val >> huffman_chunk_bits).to_int() &
    ((1 << (self.max_bits - huffman_chunk_bits)) - 1)
  let link_entry = link_table[suffix]
  if link_entry == 0U {
    raise CompressError::CorruptInput("invalid Huffman code")
  }
  let n = (link_entry & 0xFFU).reinterpret_as_int()
  let sym = (link_entry >> 8).reinterpret_as_int()
  bit_buf.val = bit_buf.val >> n
  bit_count.val -= n
  sym
}
