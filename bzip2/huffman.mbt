///|
/// bzip2 Huffman decoder using canonical codes with MSB-first reading.
priv struct Bzip2HuffmanDecoder {
  min_len : Int
  max_len : Int
  // For each code length i: limits[i] is the max code value (inclusive)
  limits : FixedArray[Int]
  // For each code length i: bases[i] is the starting index in perms
  bases : FixedArray[Int]
  // Symbol permutation sorted by (code_length, symbol)
  perms : FixedArray[Int]
}

///|
const BZIP2_MAX_CODE_LEN : Int = 20

///|
fn Bzip2HuffmanDecoder::build(
  lengths : FixedArray[Int],
  num_symbols : Int,
) -> Bzip2HuffmanDecoder raise Bzip2Error {
  // Find min and max code lengths
  let mut min_len = BZIP2_MAX_CODE_LEN + 1
  let mut max_len = 0
  for i in 0..<num_symbols {
    if lengths[i] > 0 {
      if lengths[i] < min_len {
        min_len = lengths[i]
      }
      if lengths[i] > max_len {
        max_len = lengths[i]
      }
    }
  }
  if max_len == 0 {
    raise Bzip2Error::CorruptData("empty bzip2 Huffman tree")
  }
  // Count codes of each length
  let count = FixedArray::make(BZIP2_MAX_CODE_LEN + 2, 0)
  for i in 0..<num_symbols {
    if lengths[i] > 0 {
      count[lengths[i]] += 1
    }
  }
  // Build bases (cumulative count) and limits
  let bases = FixedArray::make(BZIP2_MAX_CODE_LEN + 2, 0)
  let limits = FixedArray::make(BZIP2_MAX_CODE_LEN + 2, 0)
  let mut code = 0
  for i in min_len..<=max_len {
    bases[i] = code - count[i] // Will be corrected below
    code += count[i]
    limits[i] = code - 1
    code = code << 1
  }
  // Now bases[i] needs adjustment: it should be the cumulative offset
  // Let's recompute: bases[i] = sum of count[j] for j < i
  let mut cum = 0
  for i in min_len..<=max_len {
    bases[i] = cum
    cum += count[i]
  }
  // Build permutation: symbols sorted by (code_length, symbol_value)
  let perms = FixedArray::make(num_symbols, 0)
  let mut idx = 0
  for len in min_len..<=max_len {
    for sym in 0..<num_symbols {
      if lengths[sym] == len {
        perms[idx] = sym
        idx += 1
      }
    }
  }
  // Now recompute limits to be actual code values, not counts.
  // For canonical Huffman: first code at length i = (first_code_at_{i-1} + count[i-1]) << 1
  let min_codes = FixedArray::make(BZIP2_MAX_CODE_LEN + 2, 0)
  let actual_limits = FixedArray::make(BZIP2_MAX_CODE_LEN + 2, -1)
  let mut c = 0
  for i in min_len..<=max_len {
    min_codes[i] = c
    actual_limits[i] = c + count[i] - 1
    c = (c + count[i]) << 1
  }
  // Adjust bases: bases[i] = cumulative_count - min_code_at_length_i
  // So that decode index = bases[i] + (code - min_codes[i]) = cumulative_offset + position_within_length
  // Actually bases[i] should allow: perms[bases[i] + (code - min_codes[i])] = symbol
  let adj_bases = FixedArray::make(BZIP2_MAX_CODE_LEN + 2, 0)
  let mut cum2 = 0
  for i in min_len..<=max_len {
    adj_bases[i] = cum2 - min_codes[i]
    cum2 += count[i]
  }
  { min_len, max_len, limits: actual_limits, bases: adj_bases, perms }
}

///|
/// Streaming Huffman decode using BitBuf. Returns None if not enough bits.
/// Requires ensure(max_len) before calling to avoid mid-symbol suspension.
fn Bzip2HuffmanDecoder::try_decode(
  self : Bzip2HuffmanDecoder,
  bb : BitBuf,
) -> Int? {
  if !bb.ensure(self.max_len) {
    return None
  }
  let mut code = 0
  for i in 1..<=self.max_len {
    let bit = bb.read_unchecked(1).reinterpret_as_int()
    code = (code << 1) | bit
    if i >= self.min_len && code <= self.limits[i] {
      return Some(self.perms[self.bases[i] + code])
    }
  }
  None // invalid code — caller should treat as error
}
