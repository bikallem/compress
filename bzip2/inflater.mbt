///|
/// Streaming bzip2 decompressor using signal protocol.
///
/// Decompresses block-by-block with O(block_size) memory.
/// Each block (up to 900KB decompressed) is decoded independently.
///
/// Usage:
///   let d = Inflater::new()
///   loop d.decode() {
///     Await => { d.src(chunk); continue d.decode() }
///     Data(out) => { write(out); continue d.decode() }
///     End => break
///     Error(e) => ...
///   }
priv struct Decoder {
  bb : BitBuf
  mut phase : InflatePhase
  mut stream_crc : UInt
  // Stream params
  mut block_size_100k : Int
  mut max_block_bytes : Int
  // Block state
  mut block_crc : UInt
  mut orig_ptr : Int
  // Symbol map
  in_use : FixedArray[Bool]
  mut num_in_use : Int
  mut alpha_size : Int
  // Huffman trees
  mut trees : Array[Bzip2HuffmanDecoder]
  mut selectors : Array[Int]
  mut num_trees : Int
  mut num_selectors : Int
  // Selector reading state
  mut selector_idx : Int
  mut selector_j : Int
  mut symmap_group : Int
  mut symmap_bitmap : UInt
  // Tree length reading state
  mut tree_idx : Int
  mut length_idx : Int
  mut current_length : Int
  lengths : FixedArray[Int]
  // Symbol decode state
  mut group_pos : Int
  mut group_no : Int
  mut current_tree_idx : Int
  mtf_list : FixedArray[Byte]
  mut tt : FixedArray[Int]
  mut decoded_len : Int
  // RUNA/RUNB state
  // in_run tracked by phase: DecodeRunSymbols/EmitRun
  mut run_len : Int
  mut run_power : Int
  mut run_byte : Byte
  // Pending non-run symbol after RUNA/RUNB loop
  mut pending_sym : Int
}

///|
priv enum InflatePhase {
  StreamHeader
  BlockMagic
  BlockHeader
  ReadSymbolMap
  ReadSymbolMapGroups
  ReadTreeParams
  ReadSelectors
  ReadSelectorUnary
  ReadTreeLengths
  ReadTreeLengthDelta
  DecodeSymbols
  DecodeRunSymbols
  EmitRun
  EndOfStream
  Done
  Failed(Bzip2Error)
}

///|
struct Inflater(Decoder)

///|
pub fn Inflater::new() -> Inflater {
  // Dummy Huffman decoder for initialization
  let dummy_tree = {
    min_len: 1,
    max_len: 1,
    limits: FixedArray::make(BZIP2_MAX_CODE_LEN + 2, -1),
    bases: FixedArray::make(BZIP2_MAX_CODE_LEN + 2, 0),
    perms: FixedArray::make(1, 0),
  }
  Inflater({
    bb: BitBuf::new(),
    phase: StreamHeader,
    stream_crc: 0U,
    block_size_100k: 0,
    max_block_bytes: 0,
    block_crc: 0U,
    orig_ptr: 0,
    in_use: FixedArray::make(256, false),
    num_in_use: 0,
    alpha_size: 0,
    trees: [dummy_tree],
    selectors: [],
    num_trees: 0,
    num_selectors: 0,
    selector_idx: 0,
    selector_j: 0,
    symmap_group: 0,
    symmap_bitmap: 0U,
    lengths: FixedArray::make(258, 0),
    tree_idx: 0,
    length_idx: 0,
    current_length: 0,
    group_pos: 0,
    group_no: -1,
    current_tree_idx: 0,
    mtf_list: FixedArray::make(256, b'\x00'),
    tt: FixedArray::make(0, 0),
    decoded_len: 0,
    run_len: 0,
    run_power: 0,
    run_byte: b'\x00',
    pending_sym: -1,
  })
}

///|
pub fn Inflater::src(self : Inflater, data : Bytes) -> Unit {
  let s = self.0
  match s.phase {
    Done | Failed(_) => ()
    _ => s.bb.set_input(data)
  }
}

///|
pub fn Inflater::decode(self : Inflater) -> Decode {
  let s = self.0
  match s.phase {
    Done => End
    Failed(e) => Error(e)
    _ => step(s)
  }
}

///|
fn fail(s : Decoder, e : Bzip2Error) -> Decode {
  s.phase = Failed(e)
  Error(e)
}

///|
fn step(s : Decoder) -> Decode {
  match s.phase {
    StreamHeader => step_stream_header(s)
    BlockMagic => step_block_magic(s)
    BlockHeader => step_block_header(s)
    ReadSymbolMap => step_read_symbol_map(s)
    ReadSymbolMapGroups => step_read_symbol_map_groups(s)
    ReadTreeParams => step_read_tree_params(s)
    ReadSelectors => step_read_selectors(s)
    ReadSelectorUnary => step_read_selector_unary(s)
    ReadTreeLengths => step_read_tree_lengths(s)
    ReadTreeLengthDelta => step_read_tree_length_delta(s)
    DecodeSymbols => step_decode_symbols(s)
    DecodeRunSymbols => step_decode_run_symbols(s)
    EmitRun => step_emit_run(s)
    EndOfStream => step_end_of_stream(s)
    Done => End
    Failed(e) => Error(e)
  }
}

///|
fn step_stream_header(s : Decoder) -> Decode {
  // Need 32 bits: 'B' 'Z' 'h' level — ensure all before consuming any
  if not(s.bb.ensure(32)) {
    return Await
  }
  let m1 = s.bb.read_unchecked(8)
  let m2 = s.bb.read_unchecked(8)
  if m1 != BZIP2_MAGIC1.to_uint() || m2 != BZIP2_MAGIC2.to_uint() {
    return fail(s, Bzip2Error::InvalidHeader("invalid bzip2 magic"))
  }
  let version = s.bb.read_unchecked(8)
  if version != b'h'.to_uint() {
    return fail(s, Bzip2Error::InvalidHeader("unsupported bzip2 version"))
  }
  let level_char = s.bb.read_unchecked(8)
  if level_char < b'1'.to_uint() || level_char > b'9'.to_uint() {
    return fail(s, Bzip2Error::InvalidHeader("invalid block size"))
  }
  s.block_size_100k = (level_char - b'0'.to_uint()).reinterpret_as_int()
  s.max_block_bytes = s.block_size_100k * 100000
  s.tt = FixedArray::make(s.max_block_bytes, 0)
  s.phase = BlockMagic
  step(s)
}

///|
fn step_block_magic(s : Decoder) -> Decode {
  // Need 48 bits: two 24-bit values
  if not(s.bb.ensure(48)) {
    return Await
  }
  let magic_hi = s.bb.read_unchecked(24)
  let magic_lo = s.bb.read_unchecked(24)
  if magic_hi == 0x177245U && magic_lo == 0x385090U {
    s.phase = EndOfStream
    return step(s)
  }
  if magic_hi != 0x314159U || magic_lo != 0x265359U {
    return fail(s, Bzip2Error::CorruptData("invalid block magic"))
  }
  s.phase = BlockHeader
  step(s)
}

///|
fn step_block_header(s : Decoder) -> Decode {
  // CRC (32) + randomized (1) + orig_ptr (24) = 57 bits
  // Ensure 57 bits — BitBuf accumulates up to 64 bits so this works
  if not(s.bb.ensure(57)) {
    return Await
  }
  let crc_hi = s.bb.read_unchecked(16)
  let crc_lo = s.bb.read_unchecked(16)
  s.block_crc = (crc_hi << 16) | crc_lo
  let randomized = s.bb.read_unchecked(1)
  if randomized != 0U {
    return fail(s, Bzip2Error::CorruptData("randomized blocks not supported"))
  }
  s.orig_ptr = s.bb.read_unchecked(24).reinterpret_as_int()
  s.phase = ReadSymbolMap
  step(s)
}

///|
fn step_read_symbol_map(s : Decoder) -> Decode {
  // Read 16-bit group bitmap
  guard s.bb.read(16) is Some(used_groups) else { return Await }
  s.symmap_bitmap = used_groups
  s.symmap_group = 0
  s.num_in_use = 0
  for i in 0..<256 {
    s.in_use[i] = false
  }
  s.phase = ReadSymbolMapGroups
  step(s)
}

///|
fn step_read_symbol_map_groups(s : Decoder) -> Decode {
  while s.symmap_group < 16 {
    let g = s.symmap_group
    if (s.symmap_bitmap & (1U << (15 - g))) != 0U {
      guard s.bb.read(16) is Some(group_bits) else { return Await }
      for j in 0..<16 {
        if (group_bits & (1U << (15 - j))) != 0U {
          s.in_use[g * 16 + j] = true
          s.num_in_use += 1
        }
      }
    }
    s.symmap_group += 1
  }
  if s.num_in_use == 0 {
    return fail(s, Bzip2Error::CorruptData("no symbols in use"))
  }
  s.alpha_size = s.num_in_use + 2
  s.phase = ReadTreeParams
  step(s)
}

///|
fn step_read_tree_params(s : Decoder) -> Decode {
  // 3 bits: num_trees + 15 bits: num_selectors = 18 bits
  if not(s.bb.ensure(18)) {
    return Await
  }
  s.num_trees = s.bb.read_unchecked(3).reinterpret_as_int()
  if s.num_trees < 2 || s.num_trees > 6 {
    return fail(s, Bzip2Error::CorruptData("invalid number of Huffman trees"))
  }
  s.num_selectors = s.bb.read_unchecked(15).reinterpret_as_int()
  if s.num_selectors < 1 {
    return fail(s, Bzip2Error::CorruptData("invalid number of selectors"))
  }
  s.selectors = Array::make(s.num_selectors, 0)
  s.selector_idx = 0
  s.phase = ReadSelectors
  step(s)
}

///|
fn step_read_selectors(s : Decoder) -> Decode {
  while s.selector_idx < s.num_selectors {
    s.selector_j = 0
    s.phase = ReadSelectorUnary
    return step(s)
  }
  // Undo MTF on selectors
  let sel_mtf = FixedArray::make(s.num_trees, 0)
  for i in 0..<s.num_trees {
    sel_mtf[i] = i
  }
  for i in 0..<s.num_selectors {
    let idx = s.selectors[i]
    let val = sel_mtf[idx]
    for j = idx; j > 0; j = j - 1 {
      sel_mtf[j] = sel_mtf[j - 1]
    }
    sel_mtf[0] = val
    s.selectors[i] = val
  }
  // Start reading tree lengths
  s.trees = []
  s.tree_idx = 0
  s.phase = ReadTreeLengths
  step(s)
}

///|
fn step_read_selector_unary(s : Decoder) -> Decode {
  // Read unary-coded selector: count 1-bits, terminated by 0
  while true {
    guard s.bb.read_bit() is Some(bit) else { return Await }
    if not(bit) {
      break
    }
    s.selector_j += 1
    if s.selector_j >= s.num_trees {
      return fail(s, Bzip2Error::CorruptData("invalid selector"))
    }
  }
  s.selectors[s.selector_idx] = s.selector_j
  s.selector_idx += 1
  s.phase = ReadSelectors
  step(s)
}

///|
fn step_read_tree_lengths(s : Decoder) -> Decode {
  if s.tree_idx >= s.num_trees {
    // All trees read, start symbol decode
    s.decoded_len = 0
    s.group_pos = 0
    s.group_no = -1
    s.current_tree_idx = 0
        // Initialize MTF list
    let mut k = 0
    for i in 0..<256 {
      if s.in_use[i] {
        s.mtf_list[k] = i.to_byte()
        k += 1
      }
    }
    s.phase = DecodeSymbols
    return step(s)
  }
  // Read initial length (5 bits) for this tree
  guard s.bb.read(5) is Some(initial_len) else { return Await }
  s.current_length = initial_len.reinterpret_as_int()
  s.length_idx = 0
  for i in 0..<s.alpha_size {
    s.lengths[i] = 0
  }
  s.phase = ReadTreeLengthDelta
  step(s)
}

///|
fn step_read_tree_length_delta(s : Decoder) -> Decode {
  while s.length_idx < s.alpha_size {
    // Each iteration reads 1-2 bits: ensure 2 so we never suspend mid-step
    if not(s.bb.ensure(2)) {
      return Await
    }
    let cont = s.bb.read_unchecked(1) != 0U
    if not(cont) {
      // Accept current length for this symbol
      if s.current_length < 1 || s.current_length > BZIP2_MAX_CODE_LEN {
        return fail(s, Bzip2Error::CorruptData("invalid code length"))
      }
      s.lengths[s.length_idx] = s.current_length
      s.length_idx += 1
    } else {
      // Adjust length: direction bit
      let dir = s.bb.read_unchecked(1) != 0U
      if dir {
        s.current_length -= 1
      } else {
        s.current_length += 1
      }
    }
  }
  // Build Huffman tree from lengths
  let result = try? Bzip2HuffmanDecoder::build(s.lengths, s.alpha_size)
  match result {
    Ok(tree) => {
      s.trees.push(tree)
      s.tree_idx += 1
      s.phase = ReadTreeLengths
      step(s)
    }
    Err(e) => fail(s, e)
  }
}

///|
fn step_decode_symbols(s : Decoder) -> Decode {
  let eob = s.num_in_use + 1
  while true {
    // Update selector group
    if s.group_pos == 0 {
      s.group_no += 1
      if s.group_no >= s.num_selectors {
        return fail(s, Bzip2Error::CorruptData("ran out of selectors"))
      }
      s.current_tree_idx = s.selectors[s.group_no]
      s.group_pos = 50
    }
    s.group_pos -= 1
    let tree = s.trees[s.current_tree_idx]
    guard tree.try_decode(s.bb) is Some(sym) else { return Await }
    if sym == eob {
      // Block complete — finalize
      return finish_block(s)
    }
    if sym == 0 || sym == 1 {
      // RUNA/RUNB: start run-length decoding
      s.run_byte = s.mtf_list[0]
      s.run_len = 0
      s.run_power = 1
      s.run_len += (sym + 1) * s.run_power
      s.run_power *= 2
            s.phase = DecodeRunSymbols
      return step(s)
    }
    // Regular symbol: MTF decode
    let mtf_idx = sym - 1
    if mtf_idx >= s.num_in_use {
      return fail(s, Bzip2Error::CorruptData("MTF index out of range"))
    }
    let byte_val = s.mtf_list[mtf_idx]
    for j = mtf_idx; j > 0; j = j - 1 {
      s.mtf_list[j] = s.mtf_list[j - 1]
    }
    s.mtf_list[0] = byte_val
    if s.decoded_len >= s.max_block_bytes {
      return fail(s, Bzip2Error::CorruptData("block too large"))
    }
    s.tt[s.decoded_len] = byte_val.to_int()
    s.decoded_len += 1
  }
  End // unreachable
}

///|
fn step_decode_run_symbols(s : Decoder) -> Decode {
  // Continue reading RUNA/RUNB symbols
  while true {
    if s.group_pos == 0 {
      s.group_no += 1
      if s.group_no >= s.num_selectors {
        return fail(s, Bzip2Error::CorruptData("ran out of selectors"))
      }
      s.current_tree_idx = s.selectors[s.group_no]
      s.group_pos = 50
    }
    s.group_pos -= 1
    let tree = s.trees[s.current_tree_idx]
    guard tree.try_decode(s.bb) is Some(sym) else { return Await }
    if sym == 0 || sym == 1 {
      s.run_len += (sym + 1) * s.run_power
      s.run_power *= 2
      continue
    }
    // Non-run symbol: emit the run, then process this symbol
    s.pending_sym = sym
    s.phase = EmitRun
    return step(s)
  }
  End // unreachable
}

///|
fn step_emit_run(s : Decoder) -> Decode {
  // Emit run_len copies of run_byte
  for _ in 0..<s.run_len {
    if s.decoded_len >= s.max_block_bytes {
      return fail(s, Bzip2Error::CorruptData("block too large"))
    }
    s.tt[s.decoded_len] = s.run_byte.to_int()
    s.decoded_len += 1
  }
  s.run_len = 0
  let sym = s.pending_sym
  if sym == s.num_in_use + 1 {
    return finish_block(s)
  }
  // Regular symbol: MTF decode
  let mtf_idx = sym - 1
  if mtf_idx >= s.num_in_use {
    return fail(s, Bzip2Error::CorruptData("MTF index out of range"))
  }
  let byte_val = s.mtf_list[mtf_idx]
  for j = mtf_idx; j > 0; j = j - 1 {
    s.mtf_list[j] = s.mtf_list[j - 1]
  }
  s.mtf_list[0] = byte_val
  if s.decoded_len >= s.max_block_bytes {
    return fail(s, Bzip2Error::CorruptData("block too large"))
  }
  s.tt[s.decoded_len] = byte_val.to_int()
  s.decoded_len += 1
  s.phase = DecodeSymbols
  step(s)
}

///|
fn finish_block(s : Decoder) -> Decode {
  if s.orig_ptr < 0 || s.orig_ptr >= s.decoded_len {
    return fail(s, Bzip2Error::CorruptData("invalid original pointer"))
  }
  let bwt_output = inverse_bwt(s.tt, s.decoded_len, s.orig_ptr)
  let result = try? undo_rle1(bwt_output)
  match result {
    Err(e) => return fail(s, e)
    Ok(block_data) => {
      // Verify block CRC
      let actual_crc = bzip2_crc32(block_data)
      if actual_crc != s.block_crc {
        return fail(
          s,
          Bzip2Error::ChecksumMismatch(expected=s.block_crc, got=actual_crc),
        )
      }
      // Update stream CRC
      s.stream_crc = ((s.stream_crc << 1) | (s.stream_crc >> 31)) ^ actual_crc
      // Reset block state for next block
      s.decoded_len = 0
      s.phase = BlockMagic
      Data(block_data)
    }
  }
}

///|
fn step_end_of_stream(s : Decoder) -> Decode {
  // Read 32-bit stream CRC
  if not(s.bb.ensure(32)) {
    return Await
  }
  let stored_crc = (s.bb.read_unchecked(16) << 16) | s.bb.read_unchecked(16)
  if stored_crc != s.stream_crc {
    return fail(
      s,
      Bzip2Error::ChecksumMismatch(expected=stored_crc, got=s.stream_crc),
    )
  }
  s.phase = Done
  End
}
