///|
/// HuffmanDecoder decodes Huffman-encoded symbols from a bit stream.
/// Uses a two-level table lookup for fast decoding.
priv struct HuffmanDecoder {
  chunks : FixedArray[UInt]
  links : Array[FixedArray[UInt]]
  min_bits : Int
  max_bits : Int
}

///|
const HUFFMAN_CHUNK_BITS : Int = 9

///|
fn HuffmanDecoder::build(
  lengths : FixedArray[Int],
) -> HuffmanDecoder raise CompressError {
  let count = FixedArray::make(MAX_CODE_LEN + 1, 0)
  let mut min_bits = MAX_CODE_LEN
  let mut max_bits = 0
  for _, n in lengths {
    if n > 0 {
      count.unsafe_set(n, count.unsafe_get(n) + 1)
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
  let next_code = FixedArray::make(MAX_CODE_LEN + 1, 0)
  for bits = 1, code = 0; bits <= max_bits; {
    let c = (code + count.unsafe_get(bits - 1)) << 1
    next_code.unsafe_set(bits, c)
    continue bits + 1, c
  }
  let chunk_size = 1 << HUFFMAN_CHUNK_BITS
  let chunks = FixedArray::make(chunk_size, 0U)
  let links : Array[FixedArray[UInt]] = []
  for sym, n in lengths {
    if n == 0 {
      continue
    }
    let c = next_code.unsafe_get(n)
    next_code.unsafe_set(n, c + 1)
    let reversed = reverse_bits(c, n)
    if n <= HUFFMAN_CHUNK_BITS {
      let entry = (sym.reinterpret_as_uint() << 8) | n.reinterpret_as_uint()
      let step = 1 << n
      let mut idx = reversed
      while idx < chunk_size {
        chunks.unsafe_set(idx, entry)
        idx += step
      }
    } else {
      let prefix = reversed & ((1 << HUFFMAN_CHUNK_BITS) - 1)
      if chunks.unsafe_get(prefix) == 0U {
        let link_idx = links.length()
        let link_bits = max_bits - HUFFMAN_CHUNK_BITS
        let link_size = 1 << link_bits
        links.push(FixedArray::make(link_size, 0U))
        chunks.unsafe_set(
          prefix,
          (link_idx.reinterpret_as_uint() << 8) |
          ((HUFFMAN_CHUNK_BITS + link_bits).reinterpret_as_uint() | 0x80U),
        )
      }
      let link_info = chunks.unsafe_get(prefix)
      let link_idx = (link_info >> 8).reinterpret_as_int()
      let link_table = links.unsafe_get(link_idx)
      let suffix = reversed >> HUFFMAN_CHUNK_BITS
      let link_bits = max_bits - HUFFMAN_CHUNK_BITS
      let entry = (sym.reinterpret_as_uint() << 8) | n.reinterpret_as_uint()
      let step = 1 << (n - HUFFMAN_CHUNK_BITS)
      let mut idx = suffix
      while idx < 1 << link_bits {
        link_table.unsafe_set(idx, entry)
        idx += step
      }
    }
  }
  { chunks, links, min_bits, max_bits }
}

///|
/// Decode a symbol from the bit buffer. Returns None if not enough bits.
fn HuffmanDecoder::decode(self : HuffmanDecoder, bb : BitBuf) -> Int? {
  bb.fill()
  if bb.count < self.min_bits {
    return None
  }
  let chunk_mask = (1UL << HUFFMAN_CHUNK_BITS) - 1UL
  let idx = (bb.buf & chunk_mask).to_int()
  let entry = self.chunks.unsafe_get(idx)
  if (entry & 0x80U) == 0U {
    let n = (entry & 0xFFU).reinterpret_as_int()
    if bb.count < n {
      return None
    }
    let s = (entry >> 8).reinterpret_as_int()
    bb.buf = bb.buf >> n
    bb.count -= n
    return Some(s)
  }
  // Link table path
  let link_idx = (entry >> 8).reinterpret_as_int()
  let link_table = self.links.unsafe_get(link_idx)
  let suffix = (bb.buf >> HUFFMAN_CHUNK_BITS).to_int() &
    ((1 << (self.max_bits - HUFFMAN_CHUNK_BITS)) - 1)
  let link_entry = link_table.unsafe_get(suffix)
  if link_entry == 0U {
    return None
  }
  let n = (link_entry & 0xFFU).reinterpret_as_int()
  if bb.count < n {
    return None
  }
  let s = (link_entry >> 8).reinterpret_as_int()
  bb.buf = bb.buf >> n
  bb.count -= n
  Some(s)
}

///|
fn reverse_bits(val : Int, n : Int) -> Int {
  let (result, _) = for result = 0, v = val, i = 0; i < n; {
    continue (result << 1) | (v & 1), v >> 1, i + 1
  } nobreak {
    (result, val)
  }
  result
}
