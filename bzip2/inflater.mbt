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
///     End => break // call finish() first once the source reaches EOF
///     Error(e) => ...
///   }
priv struct Decoder {
  mut bb : BitBuf
  mut phase : InflatePhase
  mut input_finished : Bool
  mut stream_crc : UInt
  // Stream params
  mut block_size_100k : Int
  mut max_block_bytes : Int
  // Block state
  mut block_crc : UInt
  mut block_randomized : Bool
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
  AwaitNextStream
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
    input_finished: false,
    stream_crc: 0U,
    block_size_100k: 0,
    max_block_bytes: 0,
    block_crc: 0U,
    block_randomized: false,
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
pub fn Inflater::src(self : Inflater, data : BytesView) -> Unit {
  let s = self.0
  if data.length() > 0 {
    s.input_finished = false
  }
  match s.phase {
    Done | Failed(_) => ()
    AwaitNextStream => if data.length() > 0 { reset_stream(s, data.to_bytes()) }
    _ => s.bb.set_input(data)
  }
}

///|
/// Marks the compressed input as complete.
///
/// Call this once the upstream source reaches EOF so the inflater can
/// distinguish a true end-of-input from an exact boundary between
/// concatenated bzip2 streams.
pub fn Inflater::finish(self : Inflater) -> Unit {
  self.0.input_finished = true
}

///|
pub fn Inflater::decode(self : Inflater) -> Decode {
  let s = self.0
  match s.phase {
    Done => End
    Failed(e) => Error(e)
    AwaitNextStream =>
      if s.input_finished {
        s.phase = Done
        End
      } else {
        Await
      }
    _ =>
      match step(s) {
        Await =>
          if s.input_finished {
            fail(s, Bzip2Error::UnexpectedEOF)
          } else {
            Await
          }
        other => other
      }
  }
}

///|
fn fail(s : Decoder, e : Bzip2Error) -> Decode {
  s.phase = Failed(e)
  Error(e)
}

///|
/// Iterative phase dispatcher. Loops until a step function produces a
/// concrete result (Await/Data/End/Error) rather than a phase transition.
fn step(s : Decoder) -> Decode {
  loop step_once(s) {
    Some(result) => result
    None => continue step_once(s)
  }
}

///|
/// Execute one phase step. Returns None when the phase changed and the
/// dispatcher should loop, or Some(result) for a concrete decoder signal.
fn step_once(s : Decoder) -> Decode? {
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
    AwaitNextStream => Some(Await)
    Done => Some(End)
    Failed(e) => Some(Error(e))
  }
}

///|
fn step_stream_header(s : Decoder) -> Decode? {
  // Need 32 bits: 'B' 'Z' 'h' level — ensure all before consuming any
  if !s.bb.ensure(32) {
    return Some(Await)
  }
  let m1 = s.bb.read_unchecked(8)
  let m2 = s.bb.read_unchecked(8)
  if m1 != BZIP2_MAGIC1.to_uint() || m2 != BZIP2_MAGIC2.to_uint() {
    return Some(fail(s, Bzip2Error::InvalidHeader("invalid bzip2 magic")))
  }
  let version = s.bb.read_unchecked(8)
  if version != b'h'.to_uint() {
    return Some(fail(s, Bzip2Error::InvalidHeader("unsupported bzip2 version")))
  }
  let level_char = s.bb.read_unchecked(8)
  if level_char < b'1'.to_uint() || level_char > b'9'.to_uint() {
    return Some(fail(s, Bzip2Error::InvalidHeader("invalid block size")))
  }
  s.block_size_100k = (level_char - b'0'.to_uint()).reinterpret_as_int()
  s.max_block_bytes = s.block_size_100k * 100000
  s.tt = FixedArray::make(s.max_block_bytes, 0)
  s.phase = BlockMagic
  None
}

///|
fn step_block_magic(s : Decoder) -> Decode? {
  // Need 48 bits: two 24-bit values
  if !s.bb.ensure(48) {
    return Some(Await)
  }
  let magic_hi = s.bb.read_unchecked(24)
  let magic_lo = s.bb.read_unchecked(24)
  if magic_hi == 0x177245U && magic_lo == 0x385090U {
    s.phase = EndOfStream
    return None
  }
  if magic_hi != 0x314159U || magic_lo != 0x265359U {
    return Some(fail(s, Bzip2Error::CorruptData("invalid block magic")))
  }
  s.phase = BlockHeader
  None
}

///|
fn step_block_header(s : Decoder) -> Decode? {
  // CRC (32) + randomized (1) + orig_ptr (24) = 57 bits
  // Ensure 57 bits — BitBuf accumulates up to 64 bits so this works
  if !s.bb.ensure(57) {
    return Some(Await)
  }
  let crc_hi = s.bb.read_unchecked(16)
  let crc_lo = s.bb.read_unchecked(16)
  s.block_crc = (crc_hi << 16) | crc_lo
  let randomized = s.bb.read_unchecked(1)
  s.block_randomized = randomized != 0U
  s.orig_ptr = s.bb.read_unchecked(24).reinterpret_as_int()
  s.phase = ReadSymbolMap
  None
}

///|
fn step_read_symbol_map(s : Decoder) -> Decode? {
  // Read 16-bit group bitmap
  guard s.bb.read(16) is Some(used_groups) else { return Some(Await) }
  s.symmap_bitmap = used_groups
  s.symmap_group = 0
  s.num_in_use = 0
  for i in 0..<256 {
    s.in_use.unsafe_set(i, false)
  }
  s.phase = ReadSymbolMapGroups
  None
}

///|
fn step_read_symbol_map_groups(s : Decoder) -> Decode? {
  while s.symmap_group < 16 {
    let g = s.symmap_group
    if (s.symmap_bitmap & (1U << (15 - g))) != 0U {
      guard s.bb.read(16) is Some(group_bits) else { return Some(Await) }
      for j in 0..<16 {
        if (group_bits & (1U << (15 - j))) != 0U {
          s.in_use.unsafe_set(g * 16 + j, true)
          s.num_in_use += 1
        }
      }
    }
    s.symmap_group += 1
  }
  if s.num_in_use == 0 {
    return Some(fail(s, Bzip2Error::CorruptData("no symbols in use")))
  }
  s.alpha_size = s.num_in_use + 2
  s.phase = ReadTreeParams
  None
}

///|
fn step_read_tree_params(s : Decoder) -> Decode? {
  // 3 bits: num_trees + 15 bits: num_selectors = 18 bits
  if !s.bb.ensure(18) {
    return Some(Await)
  }
  s.num_trees = s.bb.read_unchecked(3).reinterpret_as_int()
  if s.num_trees < 2 || s.num_trees > 6 {
    return Some(
      fail(s, Bzip2Error::CorruptData("invalid number of Huffman trees")),
    )
  }
  s.num_selectors = s.bb.read_unchecked(15).reinterpret_as_int()
  if s.num_selectors < 1 {
    return Some(fail(s, Bzip2Error::CorruptData("invalid number of selectors")))
  }
  s.selectors = Array::make(s.num_selectors, 0)
  s.selector_idx = 0
  s.phase = ReadSelectors
  None
}

///|
fn step_read_selectors(s : Decoder) -> Decode? {
  if s.selector_idx < s.num_selectors {
    s.selector_j = 0
    s.phase = ReadSelectorUnary
    return None
  }
  // Undo MTF on selectors
  let sel_mtf = FixedArray::make(s.num_trees, 0)
  for i in 0..<s.num_trees {
    sel_mtf.unsafe_set(i, i)
  }
  for i in 0..<s.num_selectors {
    let idx = s.selectors[i]
    let val = sel_mtf.unsafe_get(idx)
    for j = idx; j > 0; j = j - 1 {
      sel_mtf.unsafe_set(j, sel_mtf.unsafe_get(j - 1))
    }
    sel_mtf.unsafe_set(0, val)
    s.selectors[i] = val
  }
  // Start reading tree lengths
  s.trees = []
  s.tree_idx = 0
  s.phase = ReadTreeLengths
  None
}

///|
fn step_read_selector_unary(s : Decoder) -> Decode? {
  // Read unary-coded selector: count 1-bits, terminated by 0
  while true {
    guard s.bb.read_bit() is Some(bit) else { return Some(Await) }
    if !bit {
      break
    }
    s.selector_j += 1
    if s.selector_j >= s.num_trees {
      return Some(fail(s, Bzip2Error::CorruptData("invalid selector")))
    }
  }
  s.selectors[s.selector_idx] = s.selector_j
  s.selector_idx += 1
  s.phase = ReadSelectors
  None
}

///|
fn step_read_tree_lengths(s : Decoder) -> Decode? {
  if s.tree_idx >= s.num_trees {
    // All trees read, start symbol decode
    s.decoded_len = 0
    s.group_pos = 0
    s.group_no = -1
    s.current_tree_idx = 0
    // Initialize MTF list
    for i = 0, k = 0; i < 256; {
      if s.in_use.unsafe_get(i) {
        s.mtf_list.unsafe_set(k, i.to_byte())
        continue i + 1, k + 1
      }
      continue i + 1, k
    }
    s.phase = DecodeSymbols
    return None
  }
  // Read initial length (5 bits) for this tree
  guard s.bb.read(5) is Some(initial_len) else { return Some(Await) }
  s.current_length = initial_len.reinterpret_as_int()
  s.length_idx = 0
  for i in 0..<s.alpha_size {
    s.lengths.unsafe_set(i, 0)
  }
  s.phase = ReadTreeLengthDelta
  None
}

///|
fn step_read_tree_length_delta(s : Decoder) -> Decode? {
  while s.length_idx < s.alpha_size {
    // Each iteration reads 1-2 bits: ensure 2 so we never suspend mid-step
    if !s.bb.ensure(2) {
      return Some(Await)
    }
    let cont = s.bb.read_unchecked(1) != 0U
    if !cont {
      // Accept current length for this symbol
      if s.current_length < 1 || s.current_length > BZIP2_MAX_CODE_LEN {
        return Some(fail(s, Bzip2Error::CorruptData("invalid code length")))
      }
      s.lengths.unsafe_set(s.length_idx, s.current_length)
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
      None
    }
    Err(e) => Some(fail(s, e))
  }
}

///|
fn step_decode_symbols(s : Decoder) -> Decode? {
  let eob = s.num_in_use + 1
  while true {
    // Update selector group
    if s.group_pos == 0 {
      s.group_no += 1
      if s.group_no >= s.num_selectors {
        return Some(fail(s, Bzip2Error::CorruptData("ran out of selectors")))
      }
      s.current_tree_idx = s.selectors[s.group_no]
      s.group_pos = 50
    }
    let tree = s.trees[s.current_tree_idx]
    guard tree.try_decode(s.bb) is Some(sym) else { return Some(Await) }
    s.group_pos -= 1
    if sym == eob {
      // Block complete — finalize
      return Some(finish_block(s))
    }
    if sym == 0 || sym == 1 {
      // RUNA/RUNB: start run-length decoding
      s.run_byte = s.mtf_list.unsafe_get(0)
      s.run_len = 0
      s.run_power = 1
      s.run_len += (sym + 1) * s.run_power
      s.run_power *= 2
      s.phase = DecodeRunSymbols
      return None
    }
    // Regular symbol: MTF decode
    let mtf_idx = sym - 1
    if mtf_idx >= s.num_in_use {
      return Some(fail(s, Bzip2Error::CorruptData("MTF index out of range")))
    }
    let byte_val = s.mtf_list.unsafe_get(mtf_idx)
    for j = mtf_idx; j > 0; j = j - 1 {
      s.mtf_list.unsafe_set(j, s.mtf_list.unsafe_get(j - 1))
    }
    s.mtf_list.unsafe_set(0, byte_val)
    if s.decoded_len >= s.max_block_bytes {
      return Some(fail(s, Bzip2Error::CorruptData("block too large")))
    }
    s.tt.unsafe_set(s.decoded_len, byte_val.to_int())
    s.decoded_len += 1
  }
  Some(End) // unreachable
}

///|
fn step_decode_run_symbols(s : Decoder) -> Decode? {
  // Continue reading RUNA/RUNB symbols
  while true {
    if s.group_pos == 0 {
      s.group_no += 1
      if s.group_no >= s.num_selectors {
        return Some(fail(s, Bzip2Error::CorruptData("ran out of selectors")))
      }
      s.current_tree_idx = s.selectors[s.group_no]
      s.group_pos = 50
    }
    let tree = s.trees[s.current_tree_idx]
    guard tree.try_decode(s.bb) is Some(sym) else { return Some(Await) }
    s.group_pos -= 1
    if sym == 0 || sym == 1 {
      s.run_len += (sym + 1) * s.run_power
      s.run_power *= 2
      continue
    }
    // Non-run symbol: emit the run, then process this symbol
    s.pending_sym = sym
    s.phase = EmitRun
    return None
  }
  Some(End) // unreachable
}

///|
fn step_emit_run(s : Decoder) -> Decode? {
  // Emit run_len copies of run_byte
  for _ in 0..<s.run_len {
    if s.decoded_len >= s.max_block_bytes {
      return Some(fail(s, Bzip2Error::CorruptData("block too large")))
    }
    s.tt.unsafe_set(s.decoded_len, s.run_byte.to_int())
    s.decoded_len += 1
  }
  s.run_len = 0
  let sym = s.pending_sym
  if sym == s.num_in_use + 1 {
    return Some(finish_block(s))
  }
  // Regular symbol: MTF decode
  let mtf_idx = sym - 1
  if mtf_idx >= s.num_in_use {
    return Some(fail(s, Bzip2Error::CorruptData("MTF index out of range")))
  }
  let byte_val = s.mtf_list.unsafe_get(mtf_idx)
  for j = mtf_idx; j > 0; j = j - 1 {
    s.mtf_list.unsafe_set(j, s.mtf_list.unsafe_get(j - 1))
  }
  s.mtf_list.unsafe_set(0, byte_val)
  if s.decoded_len >= s.max_block_bytes {
    return Some(fail(s, Bzip2Error::CorruptData("block too large")))
  }
  s.tt.unsafe_set(s.decoded_len, byte_val.to_int())
  s.decoded_len += 1
  s.phase = DecodeSymbols
  None
}

///|
fn finish_block(s : Decoder) -> Decode {
  if s.orig_ptr < 0 || s.orig_ptr >= s.decoded_len {
    return fail(s, Bzip2Error::CorruptData("invalid original pointer"))
  }
  let bwt_output = inverse_bwt(s.tt, s.decoded_len, s.orig_ptr)
  let block_input = if s.block_randomized {
    bzip2_apply_randomization(bwt_output)
  } else {
    bwt_output
  }
  let result = try? undo_rle1(block_input, s.max_block_bytes)
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
      Data(block_data[:])
    }
  }
}

///|
fn step_end_of_stream(s : Decoder) -> Decode? {
  // Read 32-bit stream CRC
  if !s.bb.ensure(32) {
    return Some(Await)
  }
  let stored_crc = (s.bb.read_unchecked(16) << 16) | s.bb.read_unchecked(16)
  if stored_crc != s.stream_crc {
    return Some(
      fail(
        s,
        Bzip2Error::ChecksumMismatch(expected=stored_crc, got=s.stream_crc),
      ),
    )
  }
  let remaining = s.bb.remaining()
  if remaining.length() > 0 {
    reset_stream(s, remaining)
    return None
  }
  if s.input_finished {
    s.phase = Done
    return Some(End)
  }
  reset_stream(s, Bytes::default())
  s.phase = AwaitNextStream
  Some(Await)
}

///|
fn reset_stream(s : Decoder, remaining : Bytes) -> Unit {
  s.bb = BitBuf::new()
  s.bb.set_input(remaining[:])
  s.phase = StreamHeader
  s.stream_crc = 0U
  s.block_size_100k = 0
  s.max_block_bytes = 0
  s.block_crc = 0U
  s.block_randomized = false
  s.orig_ptr = 0
  s.num_in_use = 0
  s.alpha_size = 0
  s.trees = []
  s.selectors = []
  s.num_trees = 0
  s.num_selectors = 0
  s.selector_idx = 0
  s.selector_j = 0
  s.symmap_group = 0
  s.symmap_bitmap = 0U
  s.tree_idx = 0
  s.length_idx = 0
  s.current_length = 0
  s.group_pos = 0
  s.group_no = -1
  s.current_tree_idx = 0
  s.decoded_len = 0
  s.run_len = 0
  s.run_power = 0
  s.run_byte = b'\x00'
  s.pending_sym = -1
}
