///|
/// Phase of the Brotli inflate state machine.
priv enum BrotliPhase {
  StreamHeader
  MetablockBegin
  MetablockHeader
  MetablockHeaderSize(Int, Int, Bool) // loop_counter, size_nibbles, is_last
  CompressedMetablockHeader
  ReadBlockTypes(Int) // loop_counter (0..2)
  ReadBlockTypeTree(Int)
  ReadBlockLenTree(Int)
  ReadBlockLength(Int)
  MetablockHeader2
  ReadContextModes(Int) // loop_counter
  ReadContextMap1
  ReadContextMap2
  ReadTreeGroup(Int) // loop_counter (0..2)
  BeforeCompressedBody
  CommandBegin
  CommandLiterals(Int, Int, Int) // insert_len, copy_len, distance_code
  CommandDistance(Int) // copy_len
  CommandCopy(Int, Int) // dist, copy_len
  UncompressedData(Int) // remaining bytes
  Metadata(Int) // remaining bytes
  MetablockDone
  Done
  Failed(BrotliError)
}

///|
/// Streaming, non-blocking Brotli decompressor (RFC 7932).
struct Inflater {
  bb : BitBuf
  mut rb : BrotliRingBuffer
  mut phase : BrotliPhase
  mut pending_output : Bytes
  mut sink : @output_sink.OutputSink?
  mut redispatch : Bool
  // Stream-level state
  mut window_bits : Int
  mut is_last_metablock : Bool
  mut meta_block_remaining_len : Int
  // Distance ring buffer
  dist_rb : FixedArray[Int]
  mut dist_rb_idx : Int
  // Block type/length state for each category (0=literal, 1=insert/copy, 2=distance)
  num_block_types : FixedArray[Int]
  block_length : FixedArray[Int]
  block_type_rb : FixedArray[Int] // ring buffer of last 2 block types per category
  // Context maps
  mut context_modes : FixedArray[Int]
  mut context_map : FixedArray[Int]
  mut dist_context_map : FixedArray[Int]
  mut num_literal_htrees : Int
  mut num_dist_htrees : Int
  // Huffman trees
  mut literal_trees : Array[BrotliHuffman]
  mut insert_copy_trees : Array[BrotliHuffman]
  mut distance_trees : Array[BrotliHuffman]
  mut block_type_trees : Array[BrotliHuffman] // 3 trees (lit, cmd, dist)
  mut block_len_trees : Array[BrotliHuffman] // 3 trees
  // Distance parameters
  mut distance_postfix_bits : Int
  mut num_direct_distance_codes : Int
  // Distance LUT (precomputed per metablock)
  dist_extra_bits : FixedArray[Int]
  dist_offset : FixedArray[Int]
  // Trivial literal context optimization
  mut trivial_literal_context : Bool
}

///|
pub fn Inflater::new() -> Inflater {
  {
    bb: BitBuf::new(),
    rb: BrotliRingBuffer::new(16), // will be resized after header
    phase: StreamHeader,
    pending_output: Bytes::default(),
    sink: None,
    redispatch: false,
    window_bits: 0,
    is_last_metablock: false,
    meta_block_remaining_len: 0,
    dist_rb: FixedArray::make(4, 0),
    dist_rb_idx: 0,
    num_block_types: FixedArray::make(3, 1),
    block_length: FixedArray::make(3, 0),
    block_type_rb: FixedArray::make(6, 0),
    context_modes: FixedArray::make(0, 0),
    context_map: FixedArray::make(0, 0),
    dist_context_map: FixedArray::make(0, 0),
    num_literal_htrees: 0,
    num_dist_htrees: 0,
    literal_trees: [],
    insert_copy_trees: [],
    distance_trees: [],
    block_type_trees: [],
    block_len_trees: [],
    distance_postfix_bits: 0,
    num_direct_distance_codes: 0,
    dist_extra_bits: FixedArray::make(544, 0),
    dist_offset: FixedArray::make(544, 0),
    trivial_literal_context: true,
  }
}

///|
pub fn Inflater::src(self : Inflater, data : BytesView) -> Unit {
  self.bb.set_input(data)
}

///|
pub fn Inflater::decode(self : Inflater) -> Decode {
  for ;; {
    if self.pending_output.length() > 0 {
      let out = self.pending_output
      self.pending_output = Bytes::default()
      return Data(out)
    }
    self.redispatch = false
    let result : Decode = match self.phase {
      Done => End
      Failed(e) => Error(e)
      StreamHeader => self.decode_stream_header()
      MetablockBegin => self.decode_metablock_begin()
      MetablockHeader => self.decode_metablock_header()
      MetablockHeaderSize(lc, sn, is_last) =>
        self.decode_metablock_header_size(lc, sn, is_last)
      CompressedMetablockHeader => self.decode_compressed_metablock_header()
      ReadBlockTypes(lc) => self.decode_read_block_types(lc)
      ReadBlockTypeTree(lc) => self.decode_read_block_type_tree(lc)
      ReadBlockLenTree(lc) => self.decode_read_block_len_tree(lc)
      ReadBlockLength(lc) => self.decode_read_block_length(lc)
      MetablockHeader2 => self.decode_metablock_header2()
      ReadContextModes(lc) => self.decode_read_context_modes(lc)
      ReadContextMap1 => self.decode_read_context_map1()
      ReadContextMap2 => self.decode_read_context_map2()
      ReadTreeGroup(lc) => self.decode_read_tree_group(lc)
      BeforeCompressedBody => self.decode_before_compressed_body()
      CommandBegin => self.decode_command_begin()
      CommandLiterals(insert_len, copy_len, distance_code) =>
        self.decode_command_literals(insert_len, copy_len, distance_code)
      CommandDistance(copy_len) => self.decode_command_distance(copy_len)
      CommandCopy(dist, copy_len) => self.decode_command_copy(dist, copy_len)
      UncompressedData(remaining) => self.decode_uncompressed(remaining)
      Metadata(remaining) => self.decode_metadata(remaining)
      MetablockDone => self.decode_metablock_done()
    }
    if self.redispatch {
      continue
    }
    return result
  }
}

///|
pub fn Inflater::remaining(self : Inflater) -> Bytes {
  self.bb.remaining()
}

///|
fn Inflater::enable_direct_output(self : Inflater, capacity : Int) -> Unit {
  self.sink = Some(@output_sink.OutputSink::new(capacity))
}

///|
fn Inflater::emit_output(self : Inflater) -> Bytes {
  match self.sink {
    Some(sink) => {
      self.rb.flush_to(sink)
      Bytes::default()
    }
    None => self.rb.flush()
  }
}

///|
fn Inflater::take_output(self : Inflater) -> Bytes {
  match self.sink {
    Some(sink) => sink.to_bytes()
    None => Bytes::default()
  }
}

///|
fn Inflater::fail(self : Inflater, e : BrotliError) -> Decode {
  self.phase = Failed(e)
  Error(e)
}

///|
fn Inflater::decode_stream_header(self : Inflater) -> Decode {
  // Window bits decoding (RFC 7932 section 9.1)
  if !self.bb.ensure(1) {
    return Await
  }
  let bit0 = self.bb.read_unchecked(1)
  if bit0 == 0 {
    self.window_bits = 16
  } else {
    if !self.bb.ensure(3) {
      return self.fail(BrotliError::InvalidHeader("truncated window bits"))
    }
    let n = self.bb.read_unchecked(3)
    if n != 0 {
      self.window_bits = 17 + n
    } else {
      if !self.bb.ensure(3) {
        return self.fail(BrotliError::InvalidHeader("truncated window bits"))
      }
      let m = self.bb.read_unchecked(3)
      if m == 1 {
        // Large window brotli marker — not supported
        return self.fail(
          BrotliError::InvalidHeader("large window brotli not supported"),
        )
      }
      if m != 0 {
        self.window_bits = 8 + m
      } else {
        self.window_bits = 17
      }
    }
  }
  self.rb = BrotliRingBuffer::new(self.window_bits)
  // Initialize distance ring buffer
  self.dist_rb[0] = 16
  self.dist_rb[1] = 15
  self.dist_rb[2] = 11
  self.dist_rb[3] = 4
  self.phase = MetablockBegin
  self.redispatch = true
  Await
}

///|
fn Inflater::decode_metablock_begin(self : Inflater) -> Decode {
  // Reset block types
  // block_type_rb: [prev, current] per category; init to [1, 0]
  for i in 0..<3 {
    self.num_block_types[i] = 1
    self.block_length[i] = 1 << 24 // BROTLI_BLOCK_SIZE_CAP
    self.block_type_rb[i * 2] = 1
    self.block_type_rb[i * 2 + 1] = 0
  }
  self.phase = MetablockHeader
  self.redispatch = true
  Await
}

///|
fn Inflater::decode_metablock_header(self : Inflater) -> Decode {
  // Read ISLAST (1 bit)
  if !self.bb.ensure(1) {
    return Await
  }
  let is_last = self.bb.read_unchecked(1) != 0
  self.is_last_metablock = is_last
  self.meta_block_remaining_len = 0
  if is_last {
    // Read ISEMPTY (1 bit)
    if !self.bb.ensure(1) {
      return self.fail(BrotliError::CorruptInput("truncated metablock header"))
    }
    let is_empty = self.bb.read_unchecked(1) != 0
    if is_empty {
      self.phase = MetablockDone
      self.redispatch = true
      return Await
    }
  }
  // Read MNIBBLES (2 bits)
  if !self.bb.ensure(2) {
    return self.fail(BrotliError::CorruptInput("truncated metablock header"))
  }
  let mnibbles = self.bb.read_unchecked(2)
  if mnibbles == 3 {
    // Metadata block
    // Read reserved bit
    if !self.bb.ensure(1) {
      return self.fail(BrotliError::CorruptInput("truncated metadata header"))
    }
    let reserved = self.bb.read_unchecked(1)
    if reserved != 0 {
      return self.fail(BrotliError::CorruptInput("reserved bit is set"))
    }
    // Read MSKIPBYTES (2 bits)
    if !self.bb.ensure(2) {
      return self.fail(BrotliError::CorruptInput("truncated metadata header"))
    }
    let mskipbytes = self.bb.read_unchecked(2)
    if mskipbytes == 0 {
      // Empty metadata
      self.phase = MetablockDone
      self.redispatch = true
      return Await
    }
    // Read MSKIPLEN
    let mut meta_len = 0
    for i in 0..<mskipbytes {
      if !self.bb.ensure(8) {
        return self.fail(
          BrotliError::CorruptInput("truncated metadata length"),
        )
      }
      let byte = self.bb.read_unchecked(8)
      meta_len = meta_len | (byte << (i * 8))
    }
    meta_len += 1
    self.bb.align_to_byte()
    self.phase = Metadata(meta_len)
    self.redispatch = true
    return Await
  }
  let size_nibbles = mnibbles + 4
  self.phase = MetablockHeaderSize(0, size_nibbles, is_last)
  self.redispatch = true
  Await
}

///|
fn Inflater::decode_metablock_header_size(
  self : Inflater,
  loop_counter : Int,
  size_nibbles : Int,
  is_last : Bool,
) -> Decode {
  let mut lc = loop_counter
  while lc < size_nibbles {
    if !self.bb.ensure(4) {
      self.phase = MetablockHeaderSize(lc, size_nibbles, is_last)
      return Await
    }
    let nibble = self.bb.read_unchecked(4)
    if lc + 1 == size_nibbles && size_nibbles > 4 && nibble == 0 {
      return self.fail(
        BrotliError::CorruptInput("exuberant nibble in metablock length"),
      )
    }
    self.meta_block_remaining_len = self.meta_block_remaining_len |
      (nibble << (lc * 4))
    lc += 1
  }
  self.meta_block_remaining_len += 1
  // Read ISUNCOMPRESSED (1 bit) if not last
  if !is_last {
    if !self.bb.ensure(1) {
      return self.fail(
        BrotliError::CorruptInput("truncated metablock header"),
      )
    }
    let is_uncompressed = self.bb.read_unchecked(1) != 0
    if is_uncompressed {
      self.bb.align_to_byte()
      self.phase = UncompressedData(self.meta_block_remaining_len)
      self.redispatch = true
      return Await
    }
  }
  if self.meta_block_remaining_len == 0 {
    self.phase = MetablockDone
    self.redispatch = true
    return Await
  }
  self.rb.ensure_size(self.meta_block_remaining_len)
  self.phase = CompressedMetablockHeader
  self.redispatch = true
  Await
}
