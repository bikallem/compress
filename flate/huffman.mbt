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
const HUFFMAN_CHUNK_BITS : Int = 9

///|
/// Builds a Huffman decoder from code lengths.
/// `lengths` maps symbol -> bit length (0 means unused).
fn HuffmanDecoder::build(
  lengths : FixedArray[Int],
) -> HuffmanDecoder raise CompressError {
  // Count codes of each length
  let count = FixedArray::make(MAX_CODE_LEN + 1, 0)
  let mut min_bits = MAX_CODE_LEN
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
  let next_code = FixedArray::make(MAX_CODE_LEN + 1, 0)
  let mut code = 0
  for bits in 1..<=max_bits {
    code = (code + count[bits - 1]) << 1
    next_code[bits] = code
  }
  // Build chunks table
  let chunk_size = 1 << HUFFMAN_CHUNK_BITS
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
    if n <= HUFFMAN_CHUNK_BITS {
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
      let prefix = reversed & ((1 << HUFFMAN_CHUNK_BITS) - 1)
      if chunks[prefix] == 0U {
        // Create link table entry
        let link_idx = links.length()
        let link_bits = max_bits - HUFFMAN_CHUNK_BITS
        let link_size = 1 << link_bits
        links.push(FixedArray::make(link_size, 0U))
        chunks[prefix] = (link_idx.reinterpret_as_uint() << 8) |
          ((HUFFMAN_CHUNK_BITS + link_bits).reinterpret_as_uint() | 0x80U)
      }
      let link_info = chunks[prefix]
      let link_idx = (link_info >> 8).reinterpret_as_int()
      let link_table = links[link_idx]
      let suffix = reversed >> HUFFMAN_CHUNK_BITS
      let link_bits = max_bits - HUFFMAN_CHUNK_BITS
      let entry = (sym.reinterpret_as_uint() << 8) | n.reinterpret_as_uint()
      let step = 1 << (n - HUFFMAN_CHUNK_BITS)
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
  br : BitReader,
) -> Int raise CompressError {
  // Ensure enough bits
  while br.count < self.max_bits {
    if br.pos >= br.data.length() {
      if br.count >= self.min_bits {
        break
      }
      raise CompressError::UnexpectedEOF
    }
    br.buf = br.buf | (br.data.unsafe_get(br.pos).to_uint64() << br.count)
    br.count += 8
    br.pos += 1
  }
  // Look up in chunks table
  let idx = (br.buf & ((1UL << HUFFMAN_CHUNK_BITS) - 1UL)).to_int()
  // Safety: idx masked to chunk table size
  let entry = self.chunks.unsafe_get(idx)
  if (entry & 0x80U) == 0U {
    // Direct hit
    let n = (entry & 0xFFU).reinterpret_as_int()
    let sym = (entry >> 8).reinterpret_as_int()
    br.buf = br.buf >> n
    br.count -= n
    return sym
  }
  // Need link table
  let link_idx = (entry >> 8).reinterpret_as_int()
  let link_table = self.links.unsafe_get(link_idx)
  let suffix = (br.buf >> HUFFMAN_CHUNK_BITS).to_int() &
    ((1 << (self.max_bits - HUFFMAN_CHUNK_BITS)) - 1)
  let link_entry = link_table.unsafe_get(suffix)
  if link_entry == 0U {
    raise CompressError::CorruptInput("invalid Huffman code")
  }
  let n = (link_entry & 0xFFU).reinterpret_as_int()
  let sym = (link_entry >> 8).reinterpret_as_int()
  br.buf = br.buf >> n
  br.count -= n
  sym
}
