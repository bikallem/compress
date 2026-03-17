///|
/// Decode compressed metablock header — block types, context modes, context maps, Huffman trees.
fn Inflater::decode_compressed_metablock_header(self : Inflater) -> Decode {
  self.block_type_trees = []
  self.block_len_trees = []
  self.phase = ReadBlockTypes(0)
  self.redispatch = true
  Await
}

///|
/// Read block type counts for literal/insert-copy/distance.
fn Inflater::decode_read_block_types(self : Inflater, lc : Int) -> Decode {
  if lc >= 3 {
    self.phase = MetablockHeader2
    self.redispatch = true
    return Await
  }
  // Decode VarLenUint8 for number of block types
  let nbltypes = match self.decode_var_len_uint8() {
    Some(v) => v + 1
    None => {
      self.phase = ReadBlockTypes(lc)
      return Await
    }
  }
  self.num_block_types[lc] = nbltypes
  if nbltypes < 2 {
    // Only one block type — no block type/length trees needed
    self.block_type_trees.push(BrotliHuffman::build_simple([0], 1, HUFFMAN_TABLE_BITS))
    self.block_len_trees.push(BrotliHuffman::build_simple([0], 1, HUFFMAN_TABLE_BITS))
    self.block_length[lc] = 1 << 24
    self.phase = ReadBlockTypes(lc + 1)
    self.redispatch = true
    return Await
  }
  self.phase = ReadBlockTypeTree(lc)
  self.redispatch = true
  Await
}

///|
fn Inflater::decode_read_block_type_tree(self : Inflater, lc : Int) -> Decode {
  let alphabet_size = self.num_block_types[lc] + 2
  let tree = match self.read_huffman_code(alphabet_size, alphabet_size) {
    Ok(t) => t
    Err(NeedInput) => {
      self.phase = ReadBlockTypeTree(lc)
      return Await
    }
    Err(FormatError(msg)) => return self.fail(BrotliError::CorruptInput(msg))
  }
  self.block_type_trees.push(tree)
  self.phase = ReadBlockLenTree(lc)
  self.redispatch = true
  Await
}

///|
fn Inflater::decode_read_block_len_tree(self : Inflater, lc : Int) -> Decode {
  let tree = match self.read_huffman_code(NUM_BLOCK_LEN_SYMBOLS, NUM_BLOCK_LEN_SYMBOLS) {
    Ok(t) => t
    Err(NeedInput) => {
      self.phase = ReadBlockLenTree(lc)
      return Await
    }
    Err(FormatError(msg)) => return self.fail(BrotliError::CorruptInput(msg))
  }
  self.block_len_trees.push(tree)
  self.phase = ReadBlockLength(lc)
  self.redispatch = true
  Await
}

///|
fn Inflater::decode_read_block_length(self : Inflater, lc : Int) -> Decode {
  let tree = self.block_len_trees[lc]
  match self.read_block_length(tree) {
    Some(bl) => {
      self.block_length[lc] = bl
      self.phase = ReadBlockTypes(lc + 1)
      self.redispatch = true
      Await
    }
    None => {
      self.phase = ReadBlockLength(lc)
      Await
    }
  }
}

///|
/// Read NPOSTFIX, NDIRECT, context modes.
fn Inflater::decode_metablock_header2(self : Inflater) -> Decode {
  if !self.bb.ensure(6) {
    return Await
  }
  let bits = self.bb.read_unchecked(6)
  self.distance_postfix_bits = bits & 3
  self.num_direct_distance_codes = (bits >> 2) << self.distance_postfix_bits
  self.context_modes = FixedArray::make(self.num_block_types[0], 0)
  self.phase = ReadContextModes(0)
  self.redispatch = true
  Await
}

///|
fn Inflater::decode_read_context_modes(self : Inflater, lc : Int) -> Decode {
  let mut i = lc
  while i < self.num_block_types[0] {
    if !self.bb.ensure(2) {
      self.phase = ReadContextModes(i)
      return Await
    }
    self.context_modes[i] = self.bb.read_unchecked(2)
    i += 1
  }
  self.phase = ReadContextMap1
  self.redispatch = true
  Await
}

///|
fn Inflater::decode_read_context_map1(self : Inflater) -> Decode {
  let context_map_size = self.num_block_types[0] << LITERAL_CONTEXT_BITS
  match self.decode_context_map(context_map_size) {
    Ok((num_htrees, cmap)) => {
      self.num_literal_htrees = num_htrees
      self.context_map = cmap
      // Detect trivial literal context
      self.trivial_literal_context = true
      for i in 0..<self.num_block_types[0] {
        let offset = i << LITERAL_CONTEXT_BITS
        let sample = self.context_map[offset]
        let mut all_same = true
        for j in 1..<(1 << LITERAL_CONTEXT_BITS) {
          if self.context_map[offset + j] != sample {
            all_same = false
            break
          }
        }
        if !all_same {
          self.trivial_literal_context = false
          break
        }
      }
      self.phase = ReadContextMap2
      self.redispatch = true
      Await
    }
    Err(NeedInput) => {
      self.phase = ReadContextMap1
      Await
    }
    Err(FormatError(msg)) => self.fail(BrotliError::CorruptInput(msg))
  }
}

///|
fn Inflater::decode_read_context_map2(self : Inflater) -> Decode {
  let context_map_size = self.num_block_types[2] << DISTANCE_CONTEXT_BITS
  let npostfix = self.distance_postfix_bits
  let ndirect = self.num_direct_distance_codes
  match self.decode_context_map(context_map_size) {
    Ok((num_htrees, cmap)) => {
      self.num_dist_htrees = num_htrees
      self.dist_context_map = cmap
      // Compute distance alphabet size
      let distance_alphabet_size = NUM_DISTANCE_SHORT_CODES +
        ndirect +
        (MAX_DISTANCE_BITS << (npostfix + 1))
      // Now read all Huffman tree groups
      self.literal_trees = []
      self.insert_copy_trees = []
      self.distance_trees = []
      // Store alphabet sizes for tree group reading
      // We'll read them in sequence: literal (256), insert_copy (704), distance
      self.phase = ReadTreeGroup(0)
      self.redispatch = true
      let _ = distance_alphabet_size
      Await
    }
    Err(NeedInput) => {
      self.phase = ReadContextMap2
      Await
    }
    Err(FormatError(msg)) => self.fail(BrotliError::CorruptInput(msg))
  }
}

///|
fn Inflater::decode_read_tree_group(self : Inflater, lc : Int) -> Decode {
  match lc {
    0 => {
      // Read literal Huffman trees
      while self.literal_trees.length() < self.num_literal_htrees {
        let tree = match self.read_huffman_code(
          NUM_LITERAL_SYMBOLS,
          NUM_LITERAL_SYMBOLS,
        ) {
          Ok(t) => t
          Err(NeedInput) => {
            self.phase = ReadTreeGroup(0)
            return Await
          }
          Err(FormatError(msg)) =>
            return self.fail(BrotliError::CorruptInput(msg))
        }
        self.literal_trees.push(tree)
      }
      self.phase = ReadTreeGroup(1)
      self.redispatch = true
      Await
    }
    1 => {
      // Read insert-copy Huffman trees (one per block type)
      let num_trees = self.num_block_types[1]
      while self.insert_copy_trees.length() < num_trees {
        let tree = match self.read_huffman_code(
          NUM_COMMAND_SYMBOLS,
          NUM_COMMAND_SYMBOLS,
        ) {
          Ok(t) => t
          Err(NeedInput) => {
            self.phase = ReadTreeGroup(1)
            return Await
          }
          Err(FormatError(msg)) =>
            return self.fail(BrotliError::CorruptInput(msg))
        }
        self.insert_copy_trees.push(tree)
      }
      self.phase = ReadTreeGroup(2)
      self.redispatch = true
      Await
    }
    2 => {
      // Read distance Huffman trees
      let npostfix = self.distance_postfix_bits
      let ndirect = self.num_direct_distance_codes
      let dist_alphabet_size_max = NUM_DISTANCE_SHORT_CODES +
        ndirect +
        (MAX_DISTANCE_BITS << (npostfix + 1))
      while self.distance_trees.length() < self.num_dist_htrees {
        let tree = match self.read_huffman_code(
          dist_alphabet_size_max,
          dist_alphabet_size_max,
        ) {
          Ok(t) => t
          Err(NeedInput) => {
            self.phase = ReadTreeGroup(2)
            return Await
          }
          Err(FormatError(msg)) =>
            return self.fail(BrotliError::CorruptInput(msg))
        }
        self.distance_trees.push(tree)
      }
      self.phase = BeforeCompressedBody
      self.redispatch = true
      Await
    }
    _ => self.fail(BrotliError::CorruptInput("invalid tree group index"))
  }
}

///|
fn Inflater::decode_before_compressed_body(self : Inflater) -> Decode {
  // Calculate distance LUT
  self.calculate_distance_lut()
  self.phase = CommandBegin
  self.redispatch = true
  Await
}
