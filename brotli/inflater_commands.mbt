///|
/// Main command begin — read insert-and-copy command.
fn Inflater::decode_command_begin(self : Inflater) -> Decode {
  if self.meta_block_remaining_len <= 0 {
    self.phase = MetablockDone
    self.redispatch = true
    return Await
  }
  // Block switch for insert/copy if needed
  if self.block_length[1] == 0 {
    if !self.decode_block_type_switch(1) {
      return Await
    }
  }
  // Read command using insert/copy Huffman tree
  let cmd_tree = self.insert_copy_trees[self.block_type_rb[3]]
  let cmd_code = match cmd_tree.decode(self.bb) {
    Some(v) => v
    None => return Await
  }
  self.block_length[1] -= 1
  // Look up in command LUT
  let lut = cmd_lut[cmd_code]
  let mut insert_len = lut.insert_len_offset.reinterpret_as_int()
  let insert_extra = lut.insert_len_extra_bits.to_int()
  if insert_extra > 0 {
    if !self.bb.ensure(insert_extra) {
      return Await
    }
    insert_len += self.bb.read_unchecked(insert_extra)
  }
  let copy_extra = lut.copy_len_extra_bits.to_int()
  let mut copy_len = lut.copy_len_offset.reinterpret_as_int()
  if copy_extra > 0 {
    if !self.bb.ensure(copy_extra) {
      return Await
    }
    copy_len += self.bb.read_unchecked(copy_extra)
  }
  let distance_code = lut.distance_code
  self.meta_block_remaining_len -= insert_len
  if insert_len == 0 {
    self.phase = CommandLiterals(0, copy_len, distance_code)
    // Skip to distance/copy directly
    self.phase = if distance_code >= 0 {
      // Implicit distance
      let dist = self.resolve_implicit_distance(distance_code)
      CommandCopy(dist, copy_len)
    } else {
      CommandDistance(copy_len)
    }
    self.redispatch = true
    return Await
  }
  self.phase = CommandLiterals(insert_len, copy_len, distance_code)
  self.redispatch = true
  Await
}

///|
/// Decode literal bytes for the insert portion of a command.
fn Inflater::decode_command_literals(
  self : Inflater,
  insert_len : Int,
  copy_len : Int,
  distance_code : Int,
) -> Decode {
  let mut remaining = insert_len
  while remaining > 0 {
    // Block switch for literals if needed
    if self.block_length[0] == 0 {
      if !self.decode_block_type_switch(0) {
        self.phase = CommandLiterals(remaining, copy_len, distance_code)
        return Await
      }
    }
    // Determine which literal Huffman tree to use
    let lit_tree = if self.trivial_literal_context {
      let block_type = self.block_type_rb[1]
      let context_offset = block_type << LITERAL_CONTEXT_BITS
      self.literal_trees[self.context_map[context_offset]]
    } else {
      let block_type = self.block_type_rb[1]
      let (p1, p2) = self.rb.prev_bytes()
      let mode = self.context_modes[block_type]
      let ctx = context_id(p1, p2, mode)
      let context_offset = (block_type << LITERAL_CONTEXT_BITS) + ctx
      self.literal_trees[self.context_map[context_offset]]
    }
    let literal = match lit_tree.decode(self.bb) {
      Some(v) => v
      None => {
        self.phase = CommandLiterals(remaining, copy_len, distance_code)
        return Await
      }
    }
    self.rb.write_byte(literal.to_byte())
    self.block_length[0] -= 1
    remaining -= 1
  }
  // Flush output if ring buffer is full
  let flushed = self.emit_output()
  if self.meta_block_remaining_len <= 0 {
    self.meta_block_remaining_len -= copy_len
    self.phase = MetablockDone
    if flushed.length() > 0 {
      self.pending_output = Bytes::default()
      return Data(flushed)
    }
    self.redispatch = true
    return Await
  }
  // Now handle distance and copy
  if distance_code >= 0 {
    // Implicit distance (from command code)
    let dist = self.resolve_implicit_distance(distance_code)
    self.meta_block_remaining_len -= copy_len
    self.phase = CommandCopy(dist, copy_len)
  } else {
    // Need to read explicit distance
    self.phase = CommandDistance(copy_len)
  }
  if flushed.length() > 0 {
    return Data(flushed)
  }
  self.redispatch = true
  Await
}

///|
/// Handle implicit distance from command code.
/// distance_code 0 means "use last distance" (repeat).
/// distance_code > 0 is impossible in this path (those go through read_distance).
fn Inflater::resolve_implicit_distance(
  self : Inflater,
  distance_code : Int,
) -> Int {
  // From C: TakeDistanceFromRingBuffer
  // For implicit distance_code 0, the C reference decrements dist_rb_idx,
  // reads dist_rb[idx & 3], then later writes it back and increments.
  // The net effect on dist_rb and dist_rb_idx is a no-op, so we simply
  // read the most recent distance without modifying the ring buffer.
  if distance_code == 0 {
    self.dist_rb[(self.dist_rb_idx + 3) & 3]
  } else {
    // Should not happen for implicit distances from command codes
    self.resolve_short_distance(distance_code)
  }
}

///|
/// Read explicit distance code.
fn Inflater::decode_command_distance(
  self : Inflater,
  copy_len : Int,
) -> Decode {
  // Block switch for distance if needed
  if self.block_length[2] == 0 {
    if !self.decode_block_type_switch(2) {
      self.phase = CommandDistance(copy_len)
      return Await
    }
  }
  // Determine distance context from copy length
  let distance_context = if copy_len > 4 { 3 } else { copy_len - 2 }
  let dist = match self.decode_distance(distance_context) {
    Some(v) => v
    None => {
      self.phase = CommandDistance(copy_len)
      return Await
    }
  }
  self.meta_block_remaining_len -= copy_len
  self.phase = CommandCopy(dist, copy_len)
  self.redispatch = true
  Await
}

///|
/// Copy bytes from ring buffer history or static dictionary.
fn Inflater::decode_command_copy(
  self : Inflater,
  dist : Int,
  copy_len : Int,
) -> Decode {
  let max_dist = self.rb.max_distance()
  if dist <= max_dist {
    // LZ77 backward reference
    self.rb.write_copy(dist, copy_len)
    let flushed = self.emit_output()
    self.phase = CommandBegin
    if flushed.length() > 0 {
      return Data(flushed)
    }
    self.redispatch = true
    return Await
  }
  // Static dictionary reference
  if copy_len >= MIN_DICTIONARY_WORD_LENGTH &&
    copy_len <= MAX_DICTIONARY_WORD_LENGTH {
    let word_length = copy_len
    let address = dist - max_dist - 1
    let size_bits = dict_size_bits_by_length[word_length]
    if size_bits == 0 {
      return self.fail(
        BrotliError::CorruptInput(
          "invalid dictionary reference: no words of length \{word_length}",
        ),
      )
    }
    let mask = (1 << size_bits) - 1
    let word_idx = address & mask
    let transform_idx = address >> size_bits
    if transform_idx >= NUM_TRANSFORMS {
      return self.fail(
        BrotliError::CorruptInput(
          "invalid transform index \{transform_idx}",
        ),
      )
    }
    let (word_offset, _) = dictionary_word(word_length, word_idx)
    if word_offset < 0 {
      return self.fail(
        BrotliError::CorruptInput("invalid dictionary word lookup"),
      )
    }
    // Apply transform
    let dst = FixedArray::make(word_length + 255 + 32 + 255, b'\x00')
    let len = transform_dictionary_word(
      dst,
      0,
      brotli_dict_data,
      word_offset,
      word_length,
      transform_idx,
    )
    // Write to ring buffer
    self.rb.write_dict(dst, 0, len)
    // Adjust meta_block_remaining_len for the difference
    // (the copy_len was already subtracted, but the actual output may differ)
    self.meta_block_remaining_len += copy_len - len
    let flushed = self.emit_output()
    self.phase = CommandBegin
    if flushed.length() > 0 {
      return Data(flushed)
    }
    self.redispatch = true
    return Await
  }
  self.fail(
    BrotliError::CorruptInput(
      "distance \{dist} exceeds history \{max_dist} with invalid copy length \{copy_len}",
    ),
  )
}

///|
/// Copy uncompressed data directly.
fn Inflater::decode_uncompressed(self : Inflater, remaining : Int) -> Decode {
  if remaining == 0 {
    let flushed = self.emit_output()
    self.phase = MetablockDone
    if flushed.length() > 0 {
      self.pending_output = Bytes::default()
      return Data(flushed)
    }
    self.redispatch = true
    return Await
  }
  let bb = self.bb
  let mut rem = remaining
  // Copy bytes from input to ring buffer
  while rem > 0 {
    let chunk = bb.next_bytes(rem)
    if chunk.length() == 0 {
      let flushed = self.emit_output()
      self.phase = UncompressedData(rem)
      if flushed.length() > 0 {
        return Data(flushed)
      }
      return Await
    }
    for i in 0..<chunk.length() {
      self.rb.write_byte(chunk[i])
    }
    rem -= chunk.length()
  }
  let flushed = self.emit_output()
  self.phase = MetablockDone
  if flushed.length() > 0 {
    self.pending_output = Bytes::default()
    return Data(flushed)
  }
  self.redispatch = true
  Await
}

///|
/// Skip metadata bytes.
fn Inflater::decode_metadata(self : Inflater, remaining : Int) -> Decode {
  if remaining == 0 {
    self.phase = MetablockDone
    self.redispatch = true
    return Await
  }
  let bb = self.bb
  let mut rem = remaining
  while rem > 0 {
    let chunk = bb.next_bytes(rem)
    if chunk.length() == 0 {
      self.phase = Metadata(rem)
      return Await
    }
    // Discard metadata bytes
    rem -= chunk.length()
  }
  self.phase = MetablockDone
  self.redispatch = true
  Await
}

///|
fn Inflater::decode_metablock_done(self : Inflater) -> Decode {
  if self.is_last_metablock {
    // Align to byte boundary and check trailing bits
    self.bb.align_to_byte()
    let flushed = self.emit_output()
    self.phase = Done
    if flushed.length() > 0 {
      self.pending_output = Bytes::default()
      return Data(flushed)
    }
    return End
  }
  self.phase = MetablockBegin
  self.redispatch = true
  Await
}
