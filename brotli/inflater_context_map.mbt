///|
/// Result of a Huffman code read or context map decode operation.
priv enum ReadResult[T] {
  Ok(T)
  Err(ReadError)
}

///|
priv enum ReadError {
  NeedInput
  FormatError(String)
}

///|
/// Decode VarLenUint8 (1..11 bits → 0..255).
fn Inflater::decode_var_len_uint8(self : Inflater) -> Int? {
  let bb = self.bb
  if !bb.ensure(1) {
    return None
  }
  if bb.read_unchecked(1) == 0 {
    return Some(0)
  }
  if !bb.ensure(3) {
    return None
  }
  let n = bb.read_unchecked(3)
  if n == 0 {
    return Some(1)
  }
  if !bb.ensure(n) {
    return None
  }
  let bits = bb.read_unchecked(n)
  Some((1 << n) + bits)
}

///|
/// Read a Huffman code from the bit stream (simple or complex prefix code).
fn Inflater::read_huffman_code(
  self : Inflater,
  alphabet_size_max : Int,
  alphabet_size_limit : Int,
) -> ReadResult[BrotliHuffman] {
  let bb = self.bb
  if !bb.ensure(2) {
    return Err(NeedInput)
  }
  let type_code = bb.read_unchecked(2)
  if type_code == 1 {
    // Simple prefix code
    if !bb.ensure(2) {
      return Err(NeedInput)
    }
    let num_symbols = bb.read_unchecked(2) + 1 // 1..4 symbols
    let max_bits = log2_floor(alphabet_size_max - 1)
    let symbols = FixedArray::make(4, 0)
    for i in 0..<num_symbols {
      if !bb.ensure(max_bits) {
        return Err(NeedInput)
      }
      let v = bb.read_unchecked(max_bits)
      if v >= alphabet_size_limit {
        return Err(FormatError("simple Huffman symbol out of range"))
      }
      symbols[i] = v
    }
    // Check for duplicates
    for i in 0..<num_symbols {
      for j = i + 1; j < num_symbols; j = j + 1 {
        if symbols[i] == symbols[j] {
          return Err(FormatError("duplicate simple Huffman symbol"))
        }
      }
    }
    // For 4 symbols, read tree-select bit
    let actual_num = if num_symbols == 4 {
      if !bb.ensure(1) {
        return Err(NeedInput)
      }
      let tree_select = bb.read_unchecked(1)
      if tree_select == 1 { 5 } else { 4 }
      // 5 means "4 symbols with different tree shape"
    } else {
      num_symbols
    }
    ReadResult::Ok(BrotliHuffman::build_simple(symbols, actual_num, HUFFMAN_TABLE_BITS))
  } else {
    // Complex prefix code
    // type_code: 0 = no skip, 2 = skip 2, 3 = skip 3
    let skip = if type_code == 0 { 0 } else { type_code }
    // Read code length code lengths using static prefix code
    let cl_code_lengths = FixedArray::make(CODE_LENGTH_CODES, 0)
    let mut space = 32
    let mut num_codes = 0
    for i in skip..<CODE_LENGTH_CODES {
      if space <= 0 {
        break
      }
      if !bb.ensure(4) {
        return Err(NeedInput)
      }
      let ix = bb.peek(4) & 0xF
      let prefix_len = code_length_prefix_length[ix]
      let prefix_val = code_length_prefix_value[ix]
      if bb.count < prefix_len {
        return Err(NeedInput)
      }
      bb.drop_bits(prefix_len)
      let code_len_idx = code_length_code_order[i]
      cl_code_lengths[code_len_idx] = prefix_val
      if prefix_val != 0 {
        space -= 32 >> prefix_val
        num_codes += 1
      }
    }
    if num_codes != 1 && space != 0 {
      return Err(FormatError("invalid code length code"))
    }
    // Build code length Huffman table
    let cl_tree = try {
      BrotliHuffman::build(cl_code_lengths, CODE_LENGTH_CODES, 5)
    } catch {
      e => return Err(FormatError(e.to_string()))
    }
    // Read symbol code lengths
    let code_lengths = FixedArray::make(alphabet_size_limit, 0)
    let mut symbol = 0
    let mut code_space = 32768
    let mut prev_code_len = INITIAL_REPEATED_CODE_LENGTH
    let mut repeat = 0
    let mut repeat_code_len = 0
    while symbol < alphabet_size_limit && code_space > 0 {
      let code_len = match cl_tree.decode(bb) {
        Some(v) => v
        None => return Err(NeedInput)
      }
      if code_len < REPEAT_PREVIOUS_CODE_LENGTH {
        // Literal code length
        repeat = 0
        if code_len != 0 {
          code_lengths[symbol] = code_len
          prev_code_len = code_len
          code_space -= 32768 >> code_len
        }
        symbol += 1
      } else if code_len == REPEAT_PREVIOUS_CODE_LENGTH {
        // Repeat previous
        let new_len = prev_code_len
        if repeat_code_len != new_len {
          repeat = 0
          repeat_code_len = new_len
        }
        if !bb.ensure(2) {
          return Err(NeedInput)
        }
        let extra = bb.read_unchecked(2)
        let old_repeat = repeat
        if repeat > 0 {
          repeat -= 2
          repeat = repeat << 2
        }
        repeat += extra + 3
        let repeat_delta = repeat - old_repeat
        if symbol + repeat_delta > alphabet_size_limit {
          return Err(FormatError("code length repeat overflow"))
        }
        for _ in 0..<repeat_delta {
          code_lengths[symbol] = repeat_code_len
          symbol += 1
        }
        if repeat_code_len != 0 {
          code_space -= repeat_delta * (32768 >> repeat_code_len)
        }
      } else {
        // code_len == 17: repeat zero
        let new_len = 0
        if repeat_code_len != new_len {
          repeat = 0
          repeat_code_len = new_len
        }
        if !bb.ensure(3) {
          return Err(NeedInput)
        }
        let extra = bb.read_unchecked(3)
        let old_repeat = repeat
        if repeat > 0 {
          repeat -= 2
          repeat = repeat << 3
        }
        repeat += extra + 3
        let repeat_delta = repeat - old_repeat
        if symbol + repeat_delta > alphabet_size_limit {
          return Err(FormatError("code length zero repeat overflow"))
        }
        // code_lengths already initialized to 0
        symbol += repeat_delta
      }
    }
    if code_space != 0 {
      return Err(FormatError("incomplete Huffman code"))
    }
    let tree = try {
      BrotliHuffman::build(code_lengths, alphabet_size_limit, HUFFMAN_TABLE_BITS)
    } catch {
      e => return Err(FormatError(e.to_string()))
    }
    ReadResult::Ok(tree)
  }
}

///|
/// Decode a context map.
fn Inflater::decode_context_map(
  self : Inflater,
  context_map_size : Int,
) -> ReadResult[(Int, FixedArray[Int])] {
  // Read num_htrees
  let num_htrees = match self.decode_var_len_uint8() {
    Some(v) => v + 1
    None => return Err(NeedInput)
  }
  let cmap = FixedArray::make(context_map_size, 0)
  if num_htrees <= 1 {
    // Trivial context map — all zeros
    return ReadResult::Ok((num_htrees, cmap))
  }
  // Read RLEMAX
  if !self.bb.ensure(1) {
    return Err(NeedInput)
  }
  let use_rle = self.bb.read_unchecked(1)
  let max_rle_prefix = if use_rle != 0 {
    if !self.bb.ensure(4) {
      return Err(NeedInput)
    }
    self.bb.read_unchecked(4) + 1
  } else {
    0
  }
  // Read Huffman table for context map entries
  let alphabet_size = num_htrees + max_rle_prefix
  let cm_tree = match self.read_huffman_code(alphabet_size, alphabet_size) {
    ReadResult::Ok(t) => t
    Err(e) => return Err(e)
  }
  // Decode context map entries
  let mut i = 0
  while i < context_map_size {
    let code = match cm_tree.decode(self.bb) {
      Some(v) => v
      None => return Err(NeedInput)
    }
    if code == 0 {
      cmap[i] = 0
      i += 1
      continue
    }
    if code > max_rle_prefix {
      cmap[i] = code - max_rle_prefix
      i += 1
      continue
    }
    // RLE zeros
    if !self.bb.ensure(code) {
      return Err(NeedInput)
    }
    let reps = self.bb.read_unchecked(code) + (1 << code)
    if i + reps > context_map_size {
      return Err(FormatError("context map RLE overflow"))
    }
    // cmap already initialized to 0
    i += reps
  }
  // Read IMTF flag
  if !self.bb.ensure(1) {
    return Err(NeedInput)
  }
  let use_imtf = self.bb.read_unchecked(1)
  if use_imtf != 0 {
    inverse_move_to_front(cmap, context_map_size)
  }
  ReadResult::Ok((num_htrees, cmap))
}

///|
/// Read a block length from the bit stream.
fn Inflater::read_block_length(
  self : Inflater,
  tree : BrotliHuffman,
) -> Int? {
  let code = match tree.decode(self.bb) {
    Some(v) => v
    None => return None
  }
  if code >= NUM_BLOCK_LEN_SYMBOLS {
    return None
  }
  let nbits = block_length_nbits[code]
  if !self.bb.ensure(nbits) {
    return None
  }
  let extra = self.bb.read_unchecked(nbits)
  Some(block_length_offset[code] + extra)
}

///|
fn inverse_move_to_front(v : FixedArray[Int], v_len : Int) -> Unit {
  let mtf = FixedArray::make(256, 0)
  for i in 0..<256 {
    mtf[i] = i
  }
  for i in 0..<v_len {
    let idx = v[i]
    let value = mtf[idx]
    v[i] = value
    // Move value to front
    let mut j = idx
    while j > 0 {
      mtf[j] = mtf[j - 1]
      j -= 1
    }
    mtf[0] = value
  }
}

///|
fn log2_floor(x : Int) -> Int {
  if x <= 0 {
    return 0
  }
  let mut result = 0
  let mut v = x
  while v > 0 {
    v = v >> 1
    result += 1
  }
  result
}
