///|
/// Brotli Huffman tree building for the encoder side.
/// Port of entropy_encode.c and related parts of brotli_bit_stream.c.

// --------------------------------------------------------------------------
// Internal Huffman tree node used during tree construction.
// --------------------------------------------------------------------------

///|
priv struct HuffmanTreeNode {
  total_count : Int
  index_left : Int // -1 for leaf
  index_right_or_value : Int // leaf: symbol index; internal: right child index
}

///|
fn HuffmanTreeNode::leaf(count : Int, value : Int) -> HuffmanTreeNode {
  { total_count: count, index_left: -1, index_right_or_value: value }
}

///|
fn HuffmanTreeNode::internal(
  count : Int,
  left : Int,
  right : Int,
) -> HuffmanTreeNode {
  { total_count: count, index_left: left, index_right_or_value: right }
}

///|
fn HuffmanTreeNode::sentinel() -> HuffmanTreeNode {
  { total_count: 0x7FFFFFFF, index_left: -1, index_right_or_value: -1 }
}

// --------------------------------------------------------------------------
// set_depth: walk tree, assign bit depths to leaf symbols.
// Returns true if all depths <= max_depth.
// --------------------------------------------------------------------------

///|
fn set_depth(
  p : Int,
  pool : FixedArray[HuffmanTreeNode],
  depth : FixedArray[Int],
  max_depth : Int,
) -> Bool {
  let stack = FixedArray::make(16, -1)
  let mut level = 0
  let mut p = p
  stack[0] = -1
  while true {
    if pool[p].index_left >= 0 {
      level += 1
      if level > max_depth {
        return false
      }
      stack[level] = pool[p].index_right_or_value
      p = pool[p].index_left
      continue
    } else {
      depth[pool[p].index_right_or_value] = level
    }
    while level >= 0 && stack[level] == -1 {
      level -= 1
    }
    if level < 0 {
      return true
    }
    p = stack[level]
    stack[level] = -1
  }
  true
}

// --------------------------------------------------------------------------
// Shell sort for HuffmanTreeNode items.
// --------------------------------------------------------------------------

///|
let shell_gaps : FixedArray[Int] = [132, 57, 23, 10, 4, 1]

///|
fn sort_huffman_tree(
  items : FixedArray[HuffmanTreeNode],
  n : Int,
  compare_less : (HuffmanTreeNode, HuffmanTreeNode) -> Bool,
) -> Unit {
  if n < 13 {
    // Insertion sort
    for i = 1; i < n; i = i + 1 {
      let tmp = items[i]
      let mut k = i
      let mut j = i - 1
      while j >= 0 && compare_less(tmp, items[j]) {
        items[k] = items[j]
        k = j
        j -= 1
      }
      items[k] = tmp
    }
  } else {
    let g_start = if n < 57 { 2 } else { 0 }
    for g = g_start; g < 6; g = g + 1 {
      let gap = shell_gaps[g]
      for i = gap; i < n; i = i + 1 {
        let mut j = i
        let tmp = items[i]
        while j >= gap && compare_less(tmp, items[j - gap]) {
          items[j] = items[j - gap]
          j -= gap
        }
        items[j] = tmp
      }
    }
  }
}

// --------------------------------------------------------------------------
// create_huffman_tree
// --------------------------------------------------------------------------

///|
/// Build a Huffman tree from population counts and return bit depths.
/// tree_limit is the maximum allowed code length. If the initial tree
/// exceeds the limit, retry with progressively bumped minimum counts.
fn create_huffman_tree(
  data : FixedArray[Int],
  length : Int,
  tree_limit : Int,
) -> FixedArray[Int] {
  let depth = FixedArray::make(length, 0)
  // Pool needs 2 * length + 1 nodes
  let tree = FixedArray::make(2 * length + 2, HuffmanTreeNode::sentinel())
  let sentinel = HuffmanTreeNode::sentinel()
  let compare_less : (HuffmanTreeNode, HuffmanTreeNode) -> Bool = fn(a, b) {
    if a.total_count != b.total_count {
      a.total_count < b.total_count
    } else {
      a.index_right_or_value > b.index_right_or_value
    }
  }
  let mut count_limit = 1
  while true {
    let mut n = 0
    // Fill leaf nodes (reverse order like C code)
    let mut ii = length
    while ii > 0 {
      ii -= 1
      if data[ii] != 0 {
        let count = if data[ii] > count_limit { data[ii] } else { count_limit }
        tree[n] = HuffmanTreeNode::leaf(count, ii)
        n += 1
      }
    }
    if n == 0 {
      break
    }
    if n == 1 {
      depth[tree[0].index_right_or_value] = 1
      break
    }
    sort_huffman_tree(tree, n, compare_less)
    // Place sentinels
    tree[n] = sentinel
    tree[n + 1] = sentinel
    let mut i = 0 // pointer to next leaf node
    let mut j = n + 1 // pointer to next non-leaf node
    for k = n - 1; k > 0; k = k - 1 {
      let left = if tree[i].total_count <= tree[j].total_count {
        let l = i
        i += 1
        l
      } else {
        let l = j
        j += 1
        l
      }
      let right = if tree[i].total_count <= tree[j].total_count {
        let r = i
        i += 1
        r
      } else {
        let r = j
        j += 1
        r
      }
      let j_end = 2 * n - k
      tree[j_end] = HuffmanTreeNode::internal(
        tree[left].total_count + tree[right].total_count,
        left,
        right,
      )
      tree[j_end + 1] = sentinel
    }
    // Reset depth before set_depth
    for idx = 0; idx < length; idx = idx + 1 {
      depth[idx] = 0
    }
    if set_depth(2 * n - 1, tree, depth, tree_limit) {
      break
    }
    // Failed to fit in tree_limit bits; bump count_limit and retry
    count_limit *= 2
    // Reset tree
    for idx = 0; idx < 2 * length + 2; idx = idx + 1 {
      tree[idx] = sentinel
    }
  }
  depth
}

// --------------------------------------------------------------------------
// Bit reversal for canonical Huffman code construction.
// --------------------------------------------------------------------------

///|
let reverse_lut : FixedArray[Int] = [
  0x00, 0x08, 0x04, 0x0C, 0x02, 0x0A, 0x06, 0x0E, 0x01, 0x09, 0x05, 0x0D,
  0x03, 0x0B, 0x07, 0x0F,
]

///|
fn reverse_bits_n(num_bits : Int, bits : Int) -> Int {
  let mut retval = reverse_lut[bits & 0x0F]
  let mut b = bits
  let mut i = 4
  while i < num_bits {
    retval = retval << 4
    b = b >> 4
    retval = retval | reverse_lut[b & 0x0F]
    i += 4
  }
  retval = retval >> ((-num_bits).land(0x03))
  retval
}

// --------------------------------------------------------------------------
// convert_bit_depths_to_symbols
// --------------------------------------------------------------------------

///|
/// Convert bit depths (code lengths) to canonical Huffman codes,
/// bit-reversed for LSB-first output.
fn convert_bit_depths_to_symbols(
  depth : FixedArray[Int],
  len : Int,
) -> FixedArray[Int] {
  let max_huffman_bits = 16
  let bl_count = FixedArray::make(max_huffman_bits, 0)
  let next_code = FixedArray::make(max_huffman_bits, 0)
  let bits = FixedArray::make(len, 0)
  for i = 0; i < len; i = i + 1 {
    bl_count[depth[i]] += 1
  }
  bl_count[0] = 0
  next_code[0] = 0
  let mut code = 0
  for i = 1; i < max_huffman_bits; i = i + 1 {
    code = (code + bl_count[i - 1]) << 1
    next_code[i] = code
  }
  for i = 0; i < len; i = i + 1 {
    if depth[i] != 0 {
      bits[i] = reverse_bits_n(depth[i], next_code[depth[i]])
      next_code[depth[i]] += 1
    }
  }
  bits
}

// --------------------------------------------------------------------------
// write_huffman_tree: RLE-encode a depth array into (tree, extra_bits).
// This produces the intermediate representation that gets further
// Huffman-compressed for the bit stream.
// --------------------------------------------------------------------------

///|
fn decide_over_rle_use(
  depth : FixedArray[Int],
  length : Int,
) -> (Bool, Bool) {
  let mut total_reps_zero = 0
  let mut total_reps_non_zero = 0
  let mut count_reps_zero = 1
  let mut count_reps_non_zero = 1
  let mut i = 0
  while i < length {
    let value = depth[i]
    let mut reps = 1
    let mut k = i + 1
    while k < length && depth[k] == value {
      reps += 1
      k += 1
    }
    if reps >= 3 && value == 0 {
      total_reps_zero += reps
      count_reps_zero += 1
    }
    if reps >= 4 && value != 0 {
      total_reps_non_zero += reps
      count_reps_non_zero += 1
    }
    i += reps
  }
  let use_rle_nz = total_reps_non_zero > count_reps_non_zero * 2
  let use_rle_z = total_reps_zero > count_reps_zero * 2
  (use_rle_nz, use_rle_z)
}

///|
fn reverse_array(v : FixedArray[Int], start : Int, end_ : Int) -> Unit {
  let mut s = start
  let mut e = end_ - 1
  while s < e {
    let tmp = v[s]
    v[s] = v[e]
    v[e] = tmp
    s += 1
    e -= 1
  }
}

///|
/// Write repetitions of a non-zero value into the RLE tree representation.
fn write_huffman_tree_reps(
  previous_value : Int,
  value : Int,
  repetitions : Int,
  tree_size : Ref[Int],
  tree : FixedArray[Int],
  extra_bits_data : FixedArray[Int],
) -> Unit {
  let mut reps = repetitions
  if previous_value != value {
    tree[tree_size.val] = value
    extra_bits_data[tree_size.val] = 0
    tree_size.val += 1
    reps -= 1
  }
  if reps == 7 {
    tree[tree_size.val] = value
    extra_bits_data[tree_size.val] = 0
    tree_size.val += 1
    reps -= 1
  }
  if reps < 3 {
    for i = 0; i < reps; i = i + 1 {
      tree[tree_size.val] = value
      extra_bits_data[tree_size.val] = 0
      tree_size.val += 1
    }
  } else {
    let start = tree_size.val
    reps -= 3
    while true {
      tree[tree_size.val] = REPEAT_PREVIOUS_CODE_LENGTH
      extra_bits_data[tree_size.val] = reps.land(0x3)
      tree_size.val += 1
      reps = reps >> 2
      if reps == 0 {
        break
      }
      reps -= 1
    }
    reverse_array(tree, start, tree_size.val)
    reverse_array(extra_bits_data, start, tree_size.val)
  }
}

///|
/// Write repetitions of zero into the RLE tree representation.
fn write_huffman_tree_reps_zeros(
  repetitions : Int,
  tree_size : Ref[Int],
  tree : FixedArray[Int],
  extra_bits_data : FixedArray[Int],
) -> Unit {
  let mut reps = repetitions
  if reps == 11 {
    tree[tree_size.val] = 0
    extra_bits_data[tree_size.val] = 0
    tree_size.val += 1
    reps -= 1
  }
  if reps < 3 {
    for i = 0; i < reps; i = i + 1 {
      tree[tree_size.val] = 0
      extra_bits_data[tree_size.val] = 0
      tree_size.val += 1
    }
  } else {
    let start = tree_size.val
    reps -= 3
    while true {
      tree[tree_size.val] = REPEAT_ZERO_CODE_LENGTH
      extra_bits_data[tree_size.val] = reps.land(0x7)
      tree_size.val += 1
      reps = reps >> 3
      if reps == 0 {
        break
      }
      reps -= 1
    }
    reverse_array(tree, start, tree_size.val)
    reverse_array(extra_bits_data, start, tree_size.val)
  }
}

///|
/// Encode a depth array into (tree, extra_bits) RLE representation.
/// Returns (tree_size, tree, extra_bits_data).
fn write_huffman_tree(
  depth : FixedArray[Int],
  length : Int,
) -> (Int, FixedArray[Int], FixedArray[Int]) {
  let tree = FixedArray::make(length + 50, 0)
  let extra_bits_data = FixedArray::make(length + 50, 0)
  let tree_size : Ref[Int] = Ref::new(0)
  let mut previous_value = INITIAL_REPEATED_CODE_LENGTH
  // Trim trailing zeros
  let mut new_length = length
  for i = 0; i < length; i = i + 1 {
    if depth[length - i - 1] == 0 {
      new_length -= 1
    } else {
      break
    }
  }
  // Decide on RLE usage
  let (use_rle_nz, use_rle_z) = if length > 50 {
    decide_over_rle_use(depth, new_length)
  } else {
    (false, false)
  }
  // Encode
  let mut i = 0
  while i < new_length {
    let value = depth[i]
    let mut reps = 1
    if (value != 0 && use_rle_nz) || (value == 0 && use_rle_z) {
      let mut k = i + 1
      while k < new_length && depth[k] == value {
        reps += 1
        k += 1
      }
    }
    if value == 0 {
      write_huffman_tree_reps_zeros(reps, tree_size, tree, extra_bits_data)
    } else {
      write_huffman_tree_reps(
        previous_value, value, reps, tree_size, tree, extra_bits_data,
      )
      previous_value = value
    }
    i += reps
  }
  (tree_size.val, tree, extra_bits_data)
}

// --------------------------------------------------------------------------
// store_huffman_tree_of_huffman_tree
// --------------------------------------------------------------------------

///|
/// Static Huffman code for encoding code-length-code-lengths (0..5).
/// Symbol 0: 00 (2 bits)
/// Symbol 1: 1110 (4 bits)
/// Symbol 2: 110 (3 bits)
/// Symbol 3: 01 (2 bits)
/// Symbol 4: 10 (2 bits)
/// Symbol 5: 1111 (4 bits)
let huff_bitlen_symbols : FixedArray[Int] = [0, 7, 3, 2, 1, 15]

///|
let huff_bitlen_nbits : FixedArray[Int] = [2, 4, 3, 2, 2, 4]

///|
fn store_huffman_tree_of_huffman_tree(
  num_codes : Int,
  code_length_bitdepth : FixedArray[Int],
  bw : BrotliBitWriter,
) -> Unit {
  let storage_order : FixedArray[Int] = [
    1, 2, 3, 4, 0, 5, 17, 6, 16, 7, 8, 9, 10, 11, 12, 13, 14, 15,
  ]
  // Find how many codes to store (trim trailing zeros in storage order)
  let mut codes_to_store = CODE_LENGTH_CODES
  if num_codes > 1 {
    while codes_to_store > 0 {
      if code_length_bitdepth[storage_order[codes_to_store - 1]] != 0 {
        break
      }
      codes_to_store -= 1
    }
  }
  // Determine skip_some
  let mut skip_some = 0
  if code_length_bitdepth[storage_order[0]] == 0 &&
    code_length_bitdepth[storage_order[1]] == 0 {
    skip_some = 2
    if code_length_bitdepth[storage_order[2]] == 0 {
      skip_some = 3
    }
  }
  bw.write_bits(2, skip_some.to_uint64())
  for i = skip_some; i < codes_to_store; i = i + 1 {
    let l = code_length_bitdepth[storage_order[i]]
    bw.write_bits(
      huff_bitlen_nbits[l], huff_bitlen_symbols[l].to_uint64(),
    )
  }
}

// --------------------------------------------------------------------------
// store_huffman_tree_to_bitmask
// --------------------------------------------------------------------------

///|
fn store_huffman_tree_to_bitmask(
  huffman_tree_size : Int,
  huffman_tree : FixedArray[Int],
  huffman_tree_extra_bits : FixedArray[Int],
  code_length_bitdepth : FixedArray[Int],
  code_length_bitdepth_symbols : FixedArray[Int],
  bw : BrotliBitWriter,
) -> Unit {
  for i = 0; i < huffman_tree_size; i = i + 1 {
    let ix = huffman_tree[i]
    bw.write_bits(
      code_length_bitdepth[ix],
      code_length_bitdepth_symbols[ix].to_uint64(),
    )
    // Extra bits
    if ix == REPEAT_PREVIOUS_CODE_LENGTH {
      bw.write_bits(2, huffman_tree_extra_bits[i].to_uint64())
    } else if ix == REPEAT_ZERO_CODE_LENGTH {
      bw.write_bits(3, huffman_tree_extra_bits[i].to_uint64())
    }
  }
}

// --------------------------------------------------------------------------
// store_simple_huffman_tree
// --------------------------------------------------------------------------

///|
fn store_simple_huffman_tree(
  depth : FixedArray[Int],
  symbols : FixedArray[Int],
  num_symbols : Int,
  max_bits : Int,
  bw : BrotliBitWriter,
) -> Unit {
  // value of 1 indicates a simple Huffman code
  bw.write_bits(2, 1UL)
  bw.write_bits(2, (num_symbols - 1).to_uint64())
  // Sort symbols by depth
  for i = 0; i < num_symbols; i = i + 1 {
    for j = i + 1; j < num_symbols; j = j + 1 {
      if depth[symbols[j]] < depth[symbols[i]] {
        let tmp = symbols[i]
        symbols[i] = symbols[j]
        symbols[j] = tmp
      }
    }
  }
  if num_symbols == 2 {
    bw.write_bits(max_bits, symbols[0].to_uint64())
    bw.write_bits(max_bits, symbols[1].to_uint64())
  } else if num_symbols == 3 {
    bw.write_bits(max_bits, symbols[0].to_uint64())
    bw.write_bits(max_bits, symbols[1].to_uint64())
    bw.write_bits(max_bits, symbols[2].to_uint64())
  } else {
    bw.write_bits(max_bits, symbols[0].to_uint64())
    bw.write_bits(max_bits, symbols[1].to_uint64())
    bw.write_bits(max_bits, symbols[2].to_uint64())
    bw.write_bits(max_bits, symbols[3].to_uint64())
    // tree-select
    let tree_sel : UInt64 = if depth[symbols[0]] == 1 { 1UL } else { 0UL }
    bw.write_bits(1, tree_sel)
  }
}

// --------------------------------------------------------------------------
// store_huffman_tree
// --------------------------------------------------------------------------

///|
/// Store a Huffman tree (depth array) into the bit stream using the full
/// Brotli format: code-length-code-lengths + RLE of code lengths.
fn store_huffman_tree(
  depth : FixedArray[Int],
  num_symbols : Int,
  bw : BrotliBitWriter,
) -> Unit {
  // RLE-encode the depth array
  let (huffman_tree_size, huffman_tree, huffman_tree_extra_bits) = write_huffman_tree(
    depth, num_symbols,
  )
  // Build histogram of the RLE symbols
  let huffman_tree_histogram = FixedArray::make(CODE_LENGTH_CODES, 0)
  for i = 0; i < huffman_tree_size; i = i + 1 {
    huffman_tree_histogram[huffman_tree[i]] += 1
  }
  // Count distinct nonzero symbols
  let mut num_codes = 0
  let mut single_code = 0
  for i = 0; i < CODE_LENGTH_CODES; i = i + 1 {
    if huffman_tree_histogram[i] != 0 {
      if num_codes == 0 {
        single_code = i
        num_codes = 1
      } else if num_codes == 1 {
        num_codes = 2
        break
      }
    }
  }
  // Build a Huffman tree over code-length codes (depth limit 5)
  let code_length_bitdepth = create_huffman_tree(
    huffman_tree_histogram, CODE_LENGTH_CODES, 5,
  )
  let code_length_bitdepth_symbols = convert_bit_depths_to_symbols(
    code_length_bitdepth, CODE_LENGTH_CODES,
  )
  // Write code-length-code-lengths
  store_huffman_tree_of_huffman_tree(num_codes, code_length_bitdepth, bw)
  // If only one code, set its depth to 0 so we skip its bits
  if num_codes == 1 {
    code_length_bitdepth[single_code] = 0
  }
  // Write the RLE-encoded tree
  store_huffman_tree_to_bitmask(
    huffman_tree_size,
    huffman_tree,
    huffman_tree_extra_bits,
    code_length_bitdepth,
    code_length_bitdepth_symbols,
    bw,
  )
}

// --------------------------------------------------------------------------
// Static code-length code tables (18 entries) for the fast path.
// --------------------------------------------------------------------------

///|
/// kCodeLengthDepth: the static depth for each of the 18 code-length symbols
/// when using the "fast" complex tree encoding.
let fast_code_length_depth : FixedArray[Int] = [
  4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 5, 5, 0, 4, 4,
]

///|
/// kCodeLengthBits: the bit patterns for each of the 18 code-length symbols.
let fast_code_length_bits : FixedArray[Int] = [
  0, 8, 4, 12, 2, 10, 6, 14, 1, 9, 5, 13, 3, 15, 31, 0, 11, 7,
]

///|
/// Write the static code-length code (40 bits) used by the fast path.
fn store_static_code_length_code(bw : BrotliBitWriter) -> Unit {
  // 40 bits: BROTLI_MAKE_UINT64_T(0x0000FFu, 0x55555554u)
  // = 0x0000FF55555554
  bw.write_bits(40, 0x0000FF55555554UL)
}

// --------------------------------------------------------------------------
// Fast-path RLE helpers for the complex code path in
// build_and_store_huffman_tree_fast.
//
// Instead of using the massive 704-entry precomputed tables from
// entropy_encode_static.h, we compute the encoding on the fly.
//
// The static code length code assigns:
//   symbols 0..12: 4-bit codes
//   symbols 13..14: 5-bit codes
//   symbol 15: unused (depth=0)
//   symbols 16 (repeat prev): 4-bit code
//   symbol 17 (repeat zero): 4-bit code
//
// For zero runs of length reps:
//   if reps < 3: emit reps copies of symbol 0 (4 bits each)
//   else: emit one symbol-17 (repeat-zero, 4 bits) + 3 extra bits
//         for groups of 8 zeros, recursing
//
// For non-zero runs: emit value symbol once (4 bits), then encode
//   (reps-1) via symbol 16 (repeat-previous, 4 bits) + 2 extra bits
//   for groups of 4.
// --------------------------------------------------------------------------

///|
/// Emit RLE for a run of `reps` zeros using the static code-length code.
fn emit_zero_reps(reps : Int, bw : BrotliBitWriter) -> Unit {
  let mut remaining = reps
  while remaining > 0 {
    if remaining < 3 {
      for i = 0; i < remaining; i = i + 1 {
        // symbol 0: depth=4, bits=0
        bw.write_bits(
          fast_code_length_depth[0],
          fast_code_length_bits[0].to_uint64(),
        )
      }
      remaining = 0
    } else {
      // Use symbol 17 (repeat zero code length)
      // It encodes 3 + extra (0..7) zeros, so up to 10 per emission.
      let extra = if remaining - 3 > 7 { 7 } else { remaining - 3 }
      // symbol 17: depth=4, bits=7 (from fast_code_length_bits[17])
      bw.write_bits(
        fast_code_length_depth[17],
        fast_code_length_bits[17].to_uint64(),
      )
      bw.write_bits(3, extra.to_uint64())
      remaining -= 3 + extra
    }
  }
}

///|
/// Emit RLE for a run of `reps` copies of non-zero `value` using the
/// static code-length code.
fn emit_nonzero_reps(
  value : Int,
  reps : Int,
  previous_value : Ref[Int],
  bw : BrotliBitWriter,
) -> Unit {
  let mut remaining = reps
  // If value differs from previous, emit one literal
  if previous_value.val != value {
    bw.write_bits(
      fast_code_length_depth[value],
      fast_code_length_bits[value].to_uint64(),
    )
    remaining -= 1
    previous_value.val = value
  }
  // Now emit remaining copies via symbol 16 (repeat previous)
  while remaining > 0 {
    if remaining < 3 {
      for i = 0; i < remaining; i = i + 1 {
        bw.write_bits(
          fast_code_length_depth[value],
          fast_code_length_bits[value].to_uint64(),
        )
      }
      remaining = 0
    } else {
      // symbol 16: encodes 3 + extra (0..3) repeats
      let extra = if remaining - 3 > 3 { 3 } else { remaining - 3 }
      // symbol 16: depth=4, bits=11 (from fast_code_length_bits[16])
      bw.write_bits(
        fast_code_length_depth[16],
        fast_code_length_bits[16].to_uint64(),
      )
      bw.write_bits(2, extra.to_uint64())
      remaining -= 3 + extra
    }
  }
}

// --------------------------------------------------------------------------
// build_and_store_huffman_tree_fast
// --------------------------------------------------------------------------

///|
/// Build a Huffman tree from histogram and write it to the bit stream.
/// Uses the fast path: simple prefix code for <= 4 symbols, or complex
/// code with the static code-length-code for more.
fn build_and_store_huffman_tree_fast(
  histogram : FixedArray[Int],
  histogram_total : Int,
  max_bits : Int,
  depth : FixedArray[Int],
  bits : FixedArray[Int],
  bw : BrotliBitWriter,
) -> Unit {
  let mut count = 0
  let symbols = FixedArray::make(4, 0)
  let mut length = 0
  let mut total = histogram_total
  while total != 0 {
    if histogram[length] != 0 {
      if count < 4 {
        symbols[count] = length
      }
      count += 1
      total -= histogram[length]
    }
    length += 1
  }
  if count <= 1 {
    // Single symbol: write simple code, depth 0
    bw.write_bits(4, 1UL) // HLIT=1, simple code
    bw.write_bits(max_bits, symbols[0].to_uint64())
    depth[symbols[0]] = 0
    bits[symbols[0]] = 0
    return
  }
  // Zero out depth
  for i = 0; i < length; i = i + 1 {
    depth[i] = 0
  }
  // Build the Huffman tree (depth limit 14 like the C code)
  let tree = FixedArray::make(2 * length + 2, HuffmanTreeNode::sentinel())
  let sentinel = HuffmanTreeNode::sentinel()
  let compare_less : (HuffmanTreeNode, HuffmanTreeNode) -> Bool = fn(a, b) {
    a.total_count < b.total_count
  }
  let mut count_limit = 1
  while true {
    let mut n = 0
    let mut ll = length
    while ll > 0 {
      ll -= 1
      if histogram[ll] != 0 {
        let c = if histogram[ll] >= count_limit {
          histogram[ll]
        } else {
          count_limit
        }
        tree[n] = HuffmanTreeNode::leaf(c, ll)
        n += 1
      }
    }
    sort_huffman_tree(tree, n, compare_less)
    tree[n] = sentinel
    tree[n + 1] = sentinel
    let mut i = 0
    let mut j = n + 1
    for k = n - 1; k > 0; k = k - 1 {
      let left = if tree[i].total_count <= tree[j].total_count {
        let l = i
        i += 1
        l
      } else {
        let l = j
        j += 1
        l
      }
      let right = if tree[i].total_count <= tree[j].total_count {
        let r = i
        i += 1
        r
      } else {
        let r = j
        j += 1
        r
      }
      let j_end = 2 * n - k
      tree[j_end] = HuffmanTreeNode::internal(
        tree[left].total_count + tree[right].total_count,
        left,
        right,
      )
      tree[j_end + 1] = sentinel
    }
    if set_depth(2 * n - 1, tree, depth, 14) {
      break
    }
    count_limit *= 2
    // Reset tree and depth
    for idx = 0; idx < 2 * length + 2; idx = idx + 1 {
      tree[idx] = sentinel
    }
    for idx = 0; idx < length; idx = idx + 1 {
      depth[idx] = 0
    }
  }
  // Convert depths to bit patterns
  let computed_bits = convert_bit_depths_to_symbols(depth, length)
  for i = 0; i < length; i = i + 1 {
    bits[i] = computed_bits[i]
  }
  if count <= 4 {
    // Simple Huffman code
    store_simple_huffman_tree(depth, symbols, count, max_bits, bw)
  } else {
    // Complex Huffman code using the static code-length code
    store_static_code_length_code(bw)
    // RLE encoding of depths
    let previous_value : Ref[Int] = Ref::new(INITIAL_REPEATED_CODE_LENGTH)
    let mut i = 0
    while i < length {
      let value = depth[i]
      let mut reps = 1
      let mut k = i + 1
      while k < length && depth[k] == value {
        reps += 1
        k += 1
      }
      i += reps
      if value == 0 {
        emit_zero_reps(reps, bw)
      } else {
        emit_nonzero_reps(value, reps, previous_value, bw)
      }
    }
  }
}

// --------------------------------------------------------------------------
// optimize_huffman_counts_for_rle
// --------------------------------------------------------------------------

///|
/// Adjust population counts so that the subsequent Huffman tree compression,
/// especially its RLE part, is more efficient.
fn optimize_huffman_counts_for_rle(
  length : Int,
  counts : FixedArray[Int],
) -> Unit {
  let mut nonzero_count = 0
  for i = 0; i < length; i = i + 1 {
    if counts[i] != 0 {
      nonzero_count += 1
    }
  }
  if nonzero_count < 16 {
    return
  }
  let mut len = length
  while len != 0 && counts[len - 1] == 0 {
    len -= 1
  }
  if len == 0 {
    return
  }
  // Count nonzeros and find smallest
  let mut nonzeros = 0
  let mut smallest_nonzero = 1 << 30
  for i = 0; i < len; i = i + 1 {
    if counts[i] != 0 {
      nonzeros += 1
      if smallest_nonzero > counts[i] {
        smallest_nonzero = counts[i]
      }
    }
  }
  if nonzeros < 5 {
    return
  }
  if smallest_nonzero < 4 {
    let zeros = len - nonzeros
    if zeros < 6 {
      for i = 1; i < len - 1; i = i + 1 {
        if counts[i - 1] != 0 && counts[i] == 0 && counts[i + 1] != 0 {
          counts[i] = 1
        }
      }
    }
  }
  if nonzeros < 28 {
    return
  }
  // Mark existing good RLE sequences
  let good_for_rle = FixedArray::make(len, false)
  let mut symbol = counts[0]
  let mut step = 0
  for i = 0; i <= len; i = i + 1 {
    if i == len || counts[i] != symbol {
      if (symbol == 0 && step >= 5) || (symbol != 0 && step >= 7) {
        for k = 0; k < step; k = k + 1 {
          good_for_rle[i - k - 1] = true
        }
      }
      step = 1
      if i != len {
        symbol = counts[i]
      }
    } else {
      step += 1
    }
  }
  // Replace counts that lead to better RLE.
  // Math in 24.8 fixed point.
  let streak_limit = 1240
  let mut stride = 0
  let mut limit = 256 * (counts[0] + counts[1] + counts[2]) / 3 + 420
  let mut sum = 0
  for i = 0; i <= len; i = i + 1 {
    if i == len ||
      good_for_rle[i] ||
      (i != 0 && good_for_rle[i - 1]) ||
      (256 * counts[i] - limit + streak_limit) >= 2 * streak_limit {
      if stride >= 4 || (stride >= 3 && sum == 0) {
        let mut count_val = (sum + stride / 2) / stride
        if count_val == 0 {
          count_val = 1
        }
        if sum == 0 {
          count_val = 0
        }
        for k = 0; k < stride; k = k + 1 {
          counts[i - k - 1] = count_val
        }
      }
      stride = 0
      sum = 0
      if i < len - 2 {
        limit = 256 * (counts[i] + counts[i + 1] + counts[i + 2]) / 3 + 420
      } else if i < len {
        limit = 256 * counts[i]
      } else {
        limit = 0
      }
    }
    stride += 1
    if i != len {
      sum += counts[i]
      if stride >= 4 {
        limit = (256 * sum + stride / 2) / stride
      }
      if stride == 4 {
        limit += 120
      }
    }
  }
}
