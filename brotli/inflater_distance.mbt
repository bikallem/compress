///|
/// Pre-calculate distance lookup table for the current metablock.
fn Inflater::calculate_distance_lut(self : Inflater) -> Unit {
  let npostfix = self.distance_postfix_bits
  let ndirect = self.num_direct_distance_codes
  let postfix = 1 << npostfix
  let mut i = NUM_DISTANCE_SHORT_CODES
  // Fill direct codes
  for j in 0..<ndirect {
    self.dist_extra_bits[i] = 0
    self.dist_offset[i] = j + 1
    i += 1
  }
  // Fill regular distance codes
  let mut bits = 1
  let mut half = 0
  let alphabet_size_limit = NUM_DISTANCE_SHORT_CODES +
    ndirect +
    (MAX_DISTANCE_BITS << (npostfix + 1))
  while i < alphabet_size_limit {
    let base = ndirect + ((((2 + half) << bits) - 4) << npostfix) + 1
    for j in 0..<postfix {
      if i >= alphabet_size_limit {
        break
      }
      self.dist_extra_bits[i] = bits
      self.dist_offset[i] = base + j
      i += 1
    }
    bits = bits + half
    half = half ^ 1
  }
}

///|
/// Decode a distance code and resolve it to actual distance.
fn Inflater::decode_distance(
  self : Inflater,
  distance_context : Int,
) -> Int? {
  // Get distance Huffman tree
  let dist_tree_idx = self.dist_context_map[
    (self.block_type_rb[5] << DISTANCE_CONTEXT_BITS) + distance_context
  ]
  let dist_tree = self.distance_trees[dist_tree_idx]
  let code = match dist_tree.decode(self.bb) {
    Some(v) => v
    None => return None
  }
  self.block_length[2] -= 1
  if code < NUM_DISTANCE_SHORT_CODES {
    // Short distance code — references distance ring buffer
    Some(self.resolve_short_distance(code))
  } else {
    // Regular distance code
    let nbits = self.dist_extra_bits[code]
    if nbits > 0 {
      if !self.bb.ensure(nbits) {
        return None
      }
      let extra = self.bb.read_unchecked(nbits)
      let dist = self.dist_offset[code] +
        (extra << self.distance_postfix_bits)
      // Update distance ring buffer
      self.dist_rb[self.dist_rb_idx & 3] = dist
      self.dist_rb_idx += 1
      Some(dist)
    } else {
      let dist = self.dist_offset[code]
      self.dist_rb[self.dist_rb_idx & 3] = dist
      self.dist_rb_idx += 1
      Some(dist)
    }
  }
}

///|
/// Resolve a short distance code (0-15) using the distance ring buffer.
/// Based on RFC 7932 Section 4 and the C reference TakeDistanceFromRingBuffer.
fn Inflater::resolve_short_distance(self : Inflater, code : Int) -> Int {
  let result = if code <= 3 {
    // Codes 0-3: direct ring buffer reference
    // C ref: offset = code - 3; dist_rb[(idx - offset) & 3] = dist_rb[(idx + 3 - code) & 3]
    self.dist_rb[(self.dist_rb_idx + 3 - code) & 3]
  } else if code < 10 {
    // Codes 4-9: last distance +/- delta
    let base = code - 4
    let index_delta = 3
    // delta = ((0x605142 >> (4 * base)) & 0xF) - 3
    let delta = ((0x605142 >> (4 * base)) & 0xF) - 3
    let d = self.dist_rb[(self.dist_rb_idx + index_delta) & 3] + delta
    if d <= 0 { 0x7FFFFFFF } else { d }
  } else {
    // Codes 10-15: second-to-last distance +/- delta
    let base = code - 10
    let index_delta = 2
    let delta = ((0x605142 >> (4 * base)) & 0xF) - 3
    let d = self.dist_rb[(self.dist_rb_idx + index_delta) & 3] + delta
    if d <= 0 { 0x7FFFFFFF } else { d }
  }
  // Update ring buffer
  self.dist_rb[self.dist_rb_idx & 3] = result
  self.dist_rb_idx += 1
  result
}

///|
/// Perform block type switching for the given category.
fn Inflater::decode_block_type_switch(
  self : Inflater,
  tree_type : Int,
) -> Bool {
  let max_block_type = self.num_block_types[tree_type]
  if max_block_type <= 1 {
    return true
  }
  let type_tree = self.block_type_trees[tree_type]
  let len_tree = self.block_len_trees[tree_type]
  let block_type = match type_tree.decode(self.bb) {
    Some(v) => v
    None => return false
  }
  let new_bl = match self.read_block_length(len_tree) {
    Some(v) => v
    None => return false
  }
  self.block_length[tree_type] = new_bl
  // Resolve block type
  let rb = self.block_type_rb
  let rb_base = tree_type * 2
  let resolved = if block_type == 1 {
    let t = rb[rb_base + 1] + 1
    if t >= max_block_type { t - max_block_type } else { t }
  } else if block_type == 0 {
    rb[rb_base]
  } else {
    let t = block_type - 2
    if t >= max_block_type { t - max_block_type } else { t }
  }
  rb[rb_base] = rb[rb_base + 1]
  rb[rb_base + 1] = resolved
  true
}
