///|
/// Brotli Huffman decoder using flat array with two-level table lookup.
/// Table entries are packed as: (value << 8) | bits
/// For second-level redirect: (offset << 8) | (total_bits | 0x80)
priv struct BrotliHuffman {
  table : FixedArray[UInt]
  root_bits : Int
  // total table size (root + all second-level tables)
  total_size : Int
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

///|
/// Build a Huffman table from code lengths.
fn BrotliHuffman::build(
  lengths : FixedArray[Int],
  alphabet_size : Int,
  root_bits : Int,
) -> BrotliHuffman raise BrotliError {
  let count = FixedArray::make(HUFFMAN_MAX_CODE_LENGTH + 1, 0)
  let mut max_bits = 0
  for i in 0..<alphabet_size {
    let n = lengths[i]
    if n > 0 {
      count[n] += 1
      if n > max_bits {
        max_bits = n
      }
    }
  }
  if max_bits == 0 {
    // All zero lengths — single symbol with code length 0
    let table = FixedArray::make(1 << root_bits, 0U)
    // Find the only symbol
    let mut sym = 0
    for i in 0..<alphabet_size {
      if lengths[i] == 0 {
        sym = i
        break
      }
    }
    let entry = (sym.reinterpret_as_uint() << 8) | 0U
    for i in 0..<(1 << root_bits) {
      table[i] = entry
    }
    return { table, root_bits, total_size: 1 << root_bits }
  }
  // Generate canonical codes
  let next_code = FixedArray::make(HUFFMAN_MAX_CODE_LENGTH + 1, 0)
  for bits = 1, code = 0; bits <= max_bits; {
    let c = (code + count[bits - 1]) << 1
    next_code[bits] = c
    continue bits + 1, c
  }
  // Calculate total table size
  let root_size = 1 << root_bits
  let mut total = root_size
  if max_bits > root_bits {
    // Count second-level tables needed
    let used_prefixes : Array[Int] = []
    for i in 0..<alphabet_size {
      let n = lengths[i]
      if n > root_bits {
        let c = next_code[n]
        let rev = reverse_bits(c, n)
        let prefix = rev & (root_size - 1)
        let mut found = false
        for p in used_prefixes {
          if p == prefix {
            found = true
            break
          }
        }
        if !found {
          used_prefixes.push(prefix)
        }
        // Ensure next_code is used properly - we don't advance here, just peek
        let _ = c
      }
    }
    // Each second-level table has size 1 << (max_bits - root_bits)
    let second_bits = max_bits - root_bits
    total += used_prefixes.length() * (1 << second_bits)
  }
  let table = FixedArray::make(total, 0U)
  // Reset next_code
  for bits = 1, code = 0; bits <= max_bits; {
    let c = (code + count[bits - 1]) << 1
    next_code[bits] = c
    continue bits + 1, c
  }
  // Fill root table for codes <= root_bits
  for i in 0..<alphabet_size {
    let n = lengths[i]
    if n == 0 || n > root_bits {
      continue
    }
    let c = next_code[n]
    next_code[n] += 1
    let reversed = reverse_bits(c, n)
    let entry = (i.reinterpret_as_uint() << 8) | n.reinterpret_as_uint()
    let step = 1 << n
    let mut idx = reversed
    while idx < root_size {
      table[idx] = entry
      idx += step
    }
  }
  // Fill second-level tables for codes > root_bits
  if max_bits > root_bits {
    let second_bits = max_bits - root_bits
    let second_size = 1 << second_bits
    let mut next_table_offset = root_size
    // Reset next_code again
    for bits = 1, code = 0; bits <= max_bits; {
      let c = (code + count[bits - 1]) << 1
      next_code[bits] = c
      continue bits + 1, c
    }
    // Skip codes that fit in root table
    for i in 0..<alphabet_size {
      let n = lengths[i]
      if n > 0 && n <= root_bits {
        next_code[n] += 1
      }
    }
    for i in 0..<alphabet_size {
      let n = lengths[i]
      if n <= root_bits {
        continue
      }
      let c = next_code[n]
      next_code[n] += 1
      let reversed = reverse_bits(c, n)
      let prefix = reversed & (root_size - 1)
      // Check if root entry has redirect
      if (table[prefix] & 0x80U) == 0U || table[prefix] == 0U {
        // Create redirect entry
        let redirect_entry = (next_table_offset.reinterpret_as_uint() << 8) |
          ((root_bits + second_bits).reinterpret_as_uint() | 0x80U)
        table[prefix] = redirect_entry
        next_table_offset += second_size
      }
      let table_offset = (table[prefix] >> 8).reinterpret_as_int()
      let suffix = reversed >> root_bits
      let entry = (i.reinterpret_as_uint() << 8) | n.reinterpret_as_uint()
      let step = 1 << (n - root_bits)
      let mut idx = suffix
      while idx < second_size {
        table[table_offset + idx] = entry
        idx += step
      }
    }
  }
  { table, root_bits, total_size: total }
}

///|
/// Build a simple Huffman table for 1-4 symbols (Brotli-specific).
fn BrotliHuffman::build_simple(
  symbols : FixedArray[Int],
  num_symbols : Int,
  root_bits : Int,
) -> BrotliHuffman {
  let table_size = 1 << root_bits
  let table = FixedArray::make(table_size, 0U)
  match num_symbols {
    1 => {
      // Single symbol, code length 0
      let entry = (symbols[0].reinterpret_as_uint() << 8) | 0U
      for i in 0..<table_size {
        table[i] = entry
      }
    }
    2 => {
      // Two symbols, code length 1 each
      let (s0, s1) = if symbols[0] <= symbols[1] {
        (symbols[0], symbols[1])
      } else {
        (symbols[1], symbols[0])
      }
      let e0 = (s0.reinterpret_as_uint() << 8) | 1U
      let e1 = (s1.reinterpret_as_uint() << 8) | 1U
      let mut i = 0
      while i < table_size {
        table[i] = e0
        table[i + 1] = e1
        i += 2
      }
    }
    3 => {
      // Three symbols: s0 has code length 1, s1 and s2 have code length 2
      let syms = [symbols[0], symbols[1], symbols[2], 0]
      // Sort first 3
      for a in 0..<2 {
        for b = a + 1; b < 3; b = b + 1 {
          if syms[b] < syms[a] {
            let t = syms[a]
            syms[a] = syms[b]
            syms[b] = t
          }
        }
      }
      let e0 = (syms[0].reinterpret_as_uint() << 8) | 1U
      let e1 = (syms[1].reinterpret_as_uint() << 8) | 2U
      let e2 = (syms[2].reinterpret_as_uint() << 8) | 2U
      let mut i = 0
      while i < table_size {
        table[i] = e0
        table[i + 1] = e1
        table[i + 2] = e0
        table[i + 3] = e2
        i += 4
      }
    }
    4 => {
      // Four symbols: s0 code length 2, s1 code length 2, s2 code length 2, s3 code length 2
      // Actually: 1,2,1,3,1,2,1,3 pattern
      let syms = [symbols[0], symbols[1], symbols[2], symbols[3]]
      // Sort all 4
      for a in 0..<3 {
        for b = a + 1; b < 4; b = b + 1 {
          if syms[b] < syms[a] {
            let t = syms[a]
            syms[a] = syms[b]
            syms[b] = t
          }
        }
      }
      // Tree shape: s0=1bit, s1=2bits, s2=3bits, s3=3bits
      let e0 = (syms[0].reinterpret_as_uint() << 8) | 1U
      let e1 = (syms[1].reinterpret_as_uint() << 8) | 2U
      let e2 = (syms[2].reinterpret_as_uint() << 8) | 3U
      let e3 = (syms[3].reinterpret_as_uint() << 8) | 3U
      let mut i = 0
      while i < table_size {
        table[i] = e0
        table[i + 1] = e1
        table[i + 2] = e0
        table[i + 3] = e2
        table[i + 4] = e0
        table[i + 5] = e1
        table[i + 6] = e0
        table[i + 7] = e3
        i += 8
      }
    }
    _ => {
      // Should not happen
      let entry = (symbols[0].reinterpret_as_uint() << 8) | 0U
      for i in 0..<table_size {
        table[i] = entry
      }
    }
  }
  { table, root_bits, total_size: table_size }
}

///|
/// Decode a symbol from the bit buffer.
fn BrotliHuffman::decode(self : BrotliHuffman, bb : BitBuf) -> Int? {
  bb.fill()
  if bb.count < 1 {
    return None
  }
  let root_mask = (1 << self.root_bits) - 1
  let idx = bb.peek(self.root_bits) & root_mask
  let entry = self.table[idx]
  if (entry & 0x80U) == 0U {
    // Direct entry
    let n = (entry & 0xFFU).reinterpret_as_int()
    if bb.count < n {
      return None
    }
    let s = (entry >> 8).reinterpret_as_int()
    bb.drop_bits(n)
    return Some(s)
  }
  // Second-level table
  let total_bits = (entry & 0x7FU).reinterpret_as_int()
  if bb.count < total_bits {
    return None
  }
  let table_offset = (entry >> 8).reinterpret_as_int()
  let second_bits = total_bits - self.root_bits
  let suffix = (bb.peek(total_bits) >> self.root_bits) & ((1 << second_bits) - 1)
  let link_entry = self.table[table_offset + suffix]
  let n = (link_entry & 0xFFU).reinterpret_as_int()
  if bb.count < n {
    return None
  }
  let s = (link_entry >> 8).reinterpret_as_int()
  bb.drop_bits(n)
  Some(s)
}
