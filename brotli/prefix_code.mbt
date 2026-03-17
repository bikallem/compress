///|
const PREFIX_CHUNK_BITS : Int = 8

///|
const MAX_PREFIX_CODE_BITS : Int = 15

///|
let code_length_code_order : FixedArray[Int] = [
  1, 2, 3, 4, 0, 5, 17, 6, 16, 7, 8, 9, 10, 11, 12, 13, 14, 15,
]

///|
priv struct PrefixDecoder {
  single_symbol : Int
  chunks : FixedArray[UInt]
  links : Array[FixedArray[UInt]]
  min_bits : Int
  max_bits : Int
}

///|
fn log2_floor_plus_one(x : Int) -> Int {
  let mut value = x
  let mut result = 0
  while value > 0 {
    value = value >> 1
    result += 1
  }
  result
}

///|
fn alphabet_bits(alphabet_size : Int) -> Int {
  if alphabet_size <= 1 {
    0
  } else {
    log2_floor_plus_one(alphabet_size - 1)
  }
}

///|
fn reverse_bits(value : Int, n : Int) -> Int {
  let (result, _) = for result = 0, current = value, i = 0; i < n; {
    continue (result << 1) | (current & 1), current >> 1, i + 1
  } nobreak {
    (result, value)
  }
  result
}

///|
fn validate_code_lengths(
  lengths : FixedArray[Int],
  max_bits : Int,
) -> (FixedArray[Int], Int, Int, Int, Int) raise BrotliError {
  let counts = FixedArray::make(max_bits + 1, 0)
  let mut non_zero = 0
  let mut min_bits = max_bits
  let mut max_len = 0
  let mut single_symbol = -1
  for symbol, length in lengths {
    guard length >= 0 && length <= max_bits else {
      raise BrotliError::CorruptInput("invalid prefix code length")
    }
    if length != 0 {
      counts[length] += 1
      non_zero += 1
      single_symbol = symbol
      if length < min_bits {
        min_bits = length
      }
      if length > max_len {
        max_len = length
      }
    }
  }
  guard non_zero > 0 else {
    raise BrotliError::CorruptInput("empty prefix code")
  }
  let mut left = 1
  if non_zero > 1 {
    for bits in 1..<=max_bits {
      left = (left << 1) - counts[bits]
      if left < 0 {
        raise BrotliError::CorruptInput("oversubscribed prefix code")
      }
    }
    guard left == 0 else {
      raise BrotliError::CorruptInput("incomplete prefix code")
    }
  }
  (counts, non_zero, min_bits, max_len, single_symbol)
}

///|
fn build_canonical_codes(
  lengths : FixedArray[Int],
  max_bits : Int,
) -> FixedArray[Int] raise BrotliError {
  let (counts, _, _, _, _) = validate_code_lengths(lengths, max_bits)
  let next_code = FixedArray::make(max_bits + 1, 0)
  for bits = 1, code = 0; bits <= max_bits; {
    let next = (code + counts[bits - 1]) << 1
    next_code[bits] = next
    continue bits + 1, next
  }
  let codes = FixedArray::make(lengths.length(), -1)
  for symbol, length in lengths {
    if length == 0 {
      continue
    }
    codes[symbol] = next_code[length]
    next_code[length] += 1
  }
  codes
}

///|
fn PrefixDecoder::build(
  lengths : FixedArray[Int],
  max_bits : Int,
) -> PrefixDecoder raise BrotliError {
  let (_, non_zero, min_bits, max_len, single_symbol) = validate_code_lengths(
    lengths, max_bits,
  )
  if non_zero == 1 {
    return {
      single_symbol,
      chunks: FixedArray::make(0, 0U),
      links: [],
      min_bits: 0,
      max_bits: 0,
    }
  }
  let codes = build_canonical_codes(lengths, max_bits)
  let chunk_size = 1 << PREFIX_CHUNK_BITS
  let chunks = FixedArray::make(chunk_size, 0U)
  let links : Array[FixedArray[UInt]] = []
  for symbol, length in lengths {
    if length == 0 {
      continue
    }
    let reversed = reverse_bits(codes[symbol], length)
    if length <= PREFIX_CHUNK_BITS {
      let entry = (symbol.reinterpret_as_uint() << 8) |
        length.reinterpret_as_uint()
      let step = 1 << length
      let mut index = reversed
      while index < chunk_size {
        chunks[index] = entry
        index += step
      }
    } else {
      let prefix = reversed & (chunk_size - 1)
      if chunks[prefix] == 0U {
        let link_bits = max_len - PREFIX_CHUNK_BITS
        let link_idx = links.length()
        links.push(FixedArray::make(1 << link_bits, 0U))
        chunks[prefix] = (link_idx.reinterpret_as_uint() << 8) |
          ((PREFIX_CHUNK_BITS + link_bits).reinterpret_as_uint() | 0x80U)
      }
      let link_info = chunks[prefix]
      let link_idx = (link_info >> 8).reinterpret_as_int()
      let link_table = links[link_idx]
      let link_bits = max_len - PREFIX_CHUNK_BITS
      let suffix = reversed >> PREFIX_CHUNK_BITS
      let entry = (symbol.reinterpret_as_uint() << 8) |
        length.reinterpret_as_uint()
      let step = 1 << (length - PREFIX_CHUNK_BITS)
      let mut index = suffix
      while index < 1 << link_bits {
        link_table[index] = entry
        index += step
      }
    }
  }
  { single_symbol: -1, chunks, links, min_bits, max_bits: max_len }
}

///|
fn PrefixDecoder::decode(self : PrefixDecoder, reader : BitReader) -> Int? {
  if self.single_symbol >= 0 {
    return Some(self.single_symbol)
  }
  reader.fill()
  if reader.count < self.min_bits {
    return None
  }
  let chunk_mask = (1UL << PREFIX_CHUNK_BITS) - 1UL
  let index = (reader.buf & chunk_mask).to_int()
  let entry = self.chunks[index]
  if entry == 0U {
    return None
  }
  if (entry & 0x80U) == 0U {
    let n = (entry & 0xFFU).reinterpret_as_int()
    if reader.count < n {
      return None
    }
    reader.drop(n)
    return Some((entry >> 8).reinterpret_as_int())
  }
  let link_idx = (entry >> 8).reinterpret_as_int()
  let link_bits = (entry & 0x7FU).reinterpret_as_int() - PREFIX_CHUNK_BITS
  let needed = PREFIX_CHUNK_BITS + link_bits
  if !reader.ensure(needed) {
    return None
  }
  let suffix = (reader.buf >> PREFIX_CHUNK_BITS).to_int() &
    ((1 << link_bits) - 1)
  let link_entry = self.links[link_idx][suffix]
  if link_entry == 0U {
    return None
  }
  let n = (link_entry & 0xFFU).reinterpret_as_int()
  if reader.count < n {
    return None
  }
  reader.drop(n)
  Some((link_entry >> 8).reinterpret_as_int())
}

///|
fn decode_code_length_prefix_symbol(
  reader : BitReader,
) -> Int raise BrotliError {
  let first_two = reader.read_required(2)
  match first_two {
    0 => 0
    1 => 4
    2 => 3
    _ => {
      let third = reader.read_required(1)
      if third == 0 {
        2
      } else {
        let fourth = reader.read_required(1)
        if fourth == 0 {
          1
        } else {
          5
        }
      }
    }
  }
}

///|
fn build_simple_prefix_decoder(
  alphabet_size : Int,
  symbols : Array[Int],
  tree_select : Int,
) -> PrefixDecoder raise BrotliError {
  let lengths = FixedArray::make(alphabet_size, 0)
  match symbols.length() {
    1 =>
      return {
        single_symbol: symbols[0],
        chunks: FixedArray::make(0, 0U),
        links: [],
        min_bits: 0,
        max_bits: 0,
      }
    2 => {
      lengths[symbols[0]] = 1
      lengths[symbols[1]] = 1
    }
    3 => {
      lengths[symbols[0]] = 1
      lengths[symbols[1]] = 2
      lengths[symbols[2]] = 2
    }
    4 =>
      if tree_select == 0 {
        lengths[symbols[0]] = 2
        lengths[symbols[1]] = 2
        lengths[symbols[2]] = 2
        lengths[symbols[3]] = 2
      } else {
        lengths[symbols[0]] = 1
        lengths[symbols[1]] = 2
        lengths[symbols[2]] = 3
        lengths[symbols[3]] = 3
      }
    _ => raise BrotliError::CorruptInput("invalid simple prefix code")
  }
  PrefixDecoder::build(lengths, MAX_PREFIX_CODE_BITS)
}

///|
fn read_simple_prefix_code(
  reader : BitReader,
  alphabet_size : Int,
) -> PrefixDecoder raise BrotliError {
  let num_symbols = reader.read_required(2) + 1
  let bits_per_symbol = alphabet_bits(alphabet_size)
  let symbols : Array[Int] = []
  for _ in 0..<num_symbols {
    let symbol = reader.read_required(bits_per_symbol)
    guard symbol < alphabet_size else {
      raise BrotliError::CorruptInput("simple prefix symbol out of range")
    }
    for _, previous in symbols {
      if previous == symbol {
        raise BrotliError::CorruptInput("duplicate simple prefix symbol")
      }
    }
    symbols.push(symbol)
  }
  let tree_select = if num_symbols == 4 { reader.read_required(1) } else { 0 }
  build_simple_prefix_decoder(alphabet_size, symbols, tree_select)
}

///|
fn read_code_length_code_decoder(
  reader : BitReader,
  hskip : Int,
) -> PrefixDecoder raise BrotliError {
  let code_length_code_lengths = FixedArray::make(18, 0)
  let mut non_zero = 0
  let mut space = 32
  let mut i = hskip
  while i < 18 {
    let symbol = code_length_code_order[i]
    let value = decode_code_length_prefix_symbol(reader)
    code_length_code_lengths[symbol] = value
    if value != 0 {
      non_zero += 1
      space -= 32 >> value
      guard space >= 0 else {
        raise BrotliError::CorruptInput("invalid code-length prefix code")
      }
      if space == 0 {
        break
      }
    }
    i += 1
  }
  guard non_zero == 1 || space == 0 else {
    raise BrotliError::CorruptInput("invalid code-length prefix code space")
  }
  PrefixDecoder::build(code_length_code_lengths, 5)
}

///|
fn read_complex_prefix_code(
  reader : BitReader,
  alphabet_size : Int,
  hskip : Int,
) -> PrefixDecoder raise BrotliError {
  let code_length_decoder = read_code_length_code_decoder(reader, hskip)
  let lengths = FixedArray::make(alphabet_size, 0)
  let mut index = 0
  let mut space = 32768
  let mut prev_code_len = 8
  let mut repeat = 0
  let mut repeat_code_len = -1
  let mut non_zero = 0
  while index < alphabet_size && space > 0 {
    let code = match code_length_decoder.decode(reader) {
      Some(value) => value
      None => raise BrotliError::UnexpectedEOF
    }
    if code < 16 {
      repeat = 0
      if code != 0 {
        prev_code_len = code
        space -= 32768 >> code
        guard space >= 0 else {
          raise BrotliError::CorruptInput("invalid prefix code space")
        }
        non_zero += 1
      }
      lengths[index] = code
      index += 1
      continue
    }
    let extra_bits = if code == 16 { 2 } else { 3 }
    let repeat_delta = reader.read_required(extra_bits)
    let new_len = if code == 16 { prev_code_len } else { 0 }
    if repeat_code_len != new_len {
      repeat = 0
      repeat_code_len = new_len
    }
    let old_repeat = repeat
    if repeat > 0 {
      repeat = repeat - 2
      repeat = repeat << (if code == 16 { 2 } else { 3 })
    }
    repeat += repeat_delta + 3
    let count = repeat - old_repeat
    guard index + count <= alphabet_size else {
      raise BrotliError::CorruptInput("repeat exceeds prefix alphabet")
    }
    if new_len != 0 {
      for i in 0..<count {
        lengths[index + i] = new_len
      }
      non_zero += count
      space -= count << (15 - new_len)
      guard space >= 0 else {
        raise BrotliError::CorruptInput("invalid repeated prefix space")
      }
    }
    index += count
  }
  guard space == 0 else {
    raise BrotliError::CorruptInput("incomplete complex prefix code")
  }
  guard non_zero >= 2 else {
    raise BrotliError::CorruptInput("complex prefix code needs two symbols")
  }
  PrefixDecoder::build(lengths, MAX_PREFIX_CODE_BITS)
}

///|
fn read_prefix_code(
  reader : BitReader,
  alphabet_size : Int,
) -> PrefixDecoder raise BrotliError {
  let kind = reader.read_required(2)
  if kind == 1 {
    return read_simple_prefix_code(reader, alphabet_size)
  }
  read_complex_prefix_code(reader, alphabet_size, kind)
}
