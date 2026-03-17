///|
/// Two-pass Brotli fragment compressor for quality 0-1.
/// Pass 1: Find backward matches using hash table (Snappy-style).
/// Pass 2: Encode using Huffman codes built from actual statistics.

const FRAGMENT_MAX_DISTANCE : Int = (1 << 18) - 16 // BROTLI_MAX_BACKWARD_LIMIT(18)

///|
const HASH_MUL32 : UInt64 = 0x1E35A7BDUL

///|
fn fragment_hash(data : FixedArray[Byte], pos : Int, shift : Int) -> Int {
  let v = data[pos].to_uint64() |
    (data[pos + 1].to_uint64() << 8) |
    (data[pos + 2].to_uint64() << 16) |
    (data[pos + 3].to_uint64() << 24)
  let h = (v << 24) * HASH_MUL32
  (h >> shift).to_int()
}

///|
fn fragment_match4(
  data : FixedArray[Byte],
  a : Int,
  b : Int,
) -> Bool {
  data[a] == data[b] &&
    data[a + 1] == data[b + 1] &&
    data[a + 2] == data[b + 2] &&
    data[a + 3] == data[b + 3]
}

///|
fn fragment_match_len(
  data : FixedArray[Byte],
  a : Int,
  b : Int,
  max_len : Int,
) -> Int {
  let mut len = 0
  while len < max_len && data[a + len] == data[b + len] {
    len += 1
  }
  len
}

///|
/// A command in the two-pass encoder: either literal bytes or a copy.
priv enum FragmentCmd {
  Literals(Int, Int) // start, count in input
  Copy(Int, Int) // distance, length
}

///|
/// Find matches in a fragment and return commands.
fn find_matches(
  input : FixedArray[Byte],
  input_offset : Int,
  input_size : Int,
  table : FixedArray[Int],
  table_bits : Int,
) -> Array[FragmentCmd] {
  let commands : Array[FragmentCmd] = []
  if input_size < 5 {
    if input_size > 0 {
      commands.push(Literals(input_offset, input_size))
    }
    return commands
  }
  let shift = 64 - table_bits
  let base = input_offset
  let end = input_offset + input_size
  let mut ip = base + 1
  let mut next_emit = base
  let mut last_distance = -1
  let ip_limit = end - 5
  while ip < ip_limit {
    // Skip loop with adaptive skipping
    let mut skip = 32
    let mut found = false
    let mut candidate = 0
    while true {
      let step = skip >> 5
      let next_ip = ip + step
      skip += step
      if next_ip > ip_limit {
        break
      }
      let hash = fragment_hash(input, ip, shift)
      candidate = table[hash] + base
      table[hash] = ip - base
      if candidate >= base && ip - candidate <= FRAGMENT_MAX_DISTANCE &&
        fragment_match4(input, ip, candidate) {
        found = true
        break
      }
      // Also check last distance
      let last_candidate = ip - last_distance
      if last_distance > 0 && last_candidate >= base &&
        fragment_match4(input, ip, last_candidate) {
        candidate = last_candidate
        table[hash] = ip - base
        found = true
        break
      }
      ip = next_ip
    }
    if !found {
      break
    }
    // Emit literals before match
    if ip > next_emit {
      commands.push(Literals(next_emit, ip - next_emit))
    }
    // Extend match
    let match_start = ip
    let max_len = end - ip
    let matched = 4 +
      fragment_match_len(input, candidate + 4, ip + 4, max_len - 4)
    let distance = ip - candidate
    commands.push(Copy(distance, matched))
    last_distance = distance
    ip += matched
    next_emit = ip
    // Try to chain: hash positions near end of match, check for another match
    if ip < ip_limit {
      // Hash a few positions before ip
      if ip - 2 >= base + 1 {
        table[fragment_hash(input, ip - 2, shift)] = ip - 2 - base
      }
      if ip - 1 >= base + 1 {
        table[fragment_hash(input, ip - 1, shift)] = ip - 1 - base
      }
      let hash = fragment_hash(input, ip, shift)
      candidate = table[hash] + base
      table[hash] = ip - base
      if candidate >= base && ip - candidate <= FRAGMENT_MAX_DISTANCE &&
        fragment_match4(input, ip, candidate) {
        continue // chain into another match
      }
      ip += 1
    }
  }
  // Emit remaining literals
  if next_emit < end {
    commands.push(Literals(next_emit, end - next_emit))
  }
  commands
}

///|
/// Encode a fragment as a complete Brotli metablock.
fn encode_fragment(
  input : FixedArray[Byte],
  input_offset : Int,
  input_size : Int,
  is_last : Bool,
  bw : BrotliBitWriter,
  table : FixedArray[Int],
  table_bits : Int,
) -> Unit {
  if input_size == 0 {
    if is_last {
      // Empty last metablock
      bw.write_bits(1, 1UL) // ISLAST
      bw.write_bits(1, 1UL) // ISEMPTY
      bw.align_to_byte()
    }
    return
  }
  // Find matches
  let commands = find_matches(input, input_offset, input_size, table, table_bits)
  // Count literal and command statistics
  let lit_histo = FixedArray::make(256, 0)
  let mut num_literals = 0
  for cmd in commands {
    match cmd {
      Literals(start, count) => {
        for i in start..<(start + count) {
          lit_histo[input[i].to_int()] += 1
        }
        num_literals += count
      }
      Copy(_, _) => ()
    }
  }
  // For now, use uncompressed metablocks for reliable output.
  // TODO: implement proper compressed metablock encoding with Huffman trees.
  let _ = lit_histo
  let _ = num_literals
  let _ = commands
  store_uncompressed_metablock(input, input_offset, input_size, bw)
  if is_last {
    bw.write_bits(1, 1UL) // ISLAST
    bw.write_bits(1, 1UL) // ISEMPTY
    bw.align_to_byte()
  }
}

///|
fn store_metablock_header(
  len : Int,
  is_uncompressed : Bool,
  bw : BrotliBitWriter,
) -> Unit {
  // ISLAST = 0
  bw.write_bits(1, 0UL)
  let nibbles = if len <= (1 << 16) {
    4
  } else if len <= (1 << 20) {
    5
  } else {
    6
  }
  bw.write_bits(2, (nibbles - 4).to_uint64())
  bw.write_bits(nibbles * 4, (len - 1).to_uint64())
  // ISUNCOMPRESSED
  bw.write_bits(1, if is_uncompressed { 1UL } else { 0UL })
}

///|
fn store_uncompressed_metablock(
  input : FixedArray[Byte],
  offset : Int,
  size : Int,
  bw : BrotliBitWriter,
) -> Unit {
  store_metablock_header(size, true, bw)
  bw.align_to_byte()
  // Copy raw bytes
  for i in 0..<size {
    bw.write_bits(8, input[offset + i].to_uint64())
  }
}

///|
// Insert length code tables (RFC 7932 Section 5)
let insert_length_bases : FixedArray[Int] = [
  0, 1, 2, 3, 4, 5, 6, 8, 10, 14, 18, 26, 34, 50, 66, 98, 130, 194, 322, 578,
  1090, 2114, 6210, 22594,
]

///|
let insert_length_extra : FixedArray[Int] = [
  0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 7, 8, 9, 10, 12, 14, 24,
]

///|
fn get_insert_length_code(insert_len : Int) -> Int {
  let mut code = 0
  for i = 23; i >= 0; i = i - 1 {
    if insert_len >= insert_length_bases[i] {
      code = i
      break
    }
  }
  code
}

///|
fn insert_length_params(code : Int) -> (Int, Int) {
  (insert_length_bases[code], insert_length_extra[code])
}

///|
// Copy length code tables
let copy_length_bases : FixedArray[Int] = [
  2, 3, 4, 5, 6, 7, 8, 9, 10, 12, 14, 18, 22, 30, 38, 54, 70, 102, 134, 198,
  326, 582, 1094, 2118,
]

///|
let copy_length_extra : FixedArray[Int] = [
  0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 7, 8, 9, 10, 24,
]

///|
fn get_copy_length_code(copy_len : Int) -> Int {
  let mut code = 0
  for i = 23; i >= 0; i = i - 1 {
    if copy_len >= copy_length_bases[i] {
      code = i
      break
    }
  }
  code
}

///|
fn copy_length_params(code : Int) -> (Int, Int) {
  (copy_length_bases[code], copy_length_extra[code])
}

///|
/// Combine insert and copy length codes into a command code.
/// This is for the "same distance" case (distance code 0).
fn combine_insert_copy(ins_code : Int, copy_code : Int) -> Int {
  // RFC 7932 Table in Section 5
  // cmd = InsertLengthCode * 8 + CopyLengthCode for small values
  // Simplified: use insert_and_copy mapping
  // The full 704-symbol alphabet: command code = mapping of (ins_code, copy_code)
  // From RFC: each row is for a range of (insert_code, copy_code) pairs
  // For quality 0-1 we use the simple formula from the command LUT
  ins_code * 8 + copy_code
}

///|
/// Combine for explicit distance case (copy codes start at offset 128).
fn combine_insert_copy_explicit_dist(ins_code : Int, copy_code : Int) -> Int {
  128 + ins_code * 8 + copy_code
}

///|
/// Encode distance as (symbol, extra_bits, extra_value) for NPOSTFIX=0, NDIRECT=0.
fn get_distance_code(distance : Int) -> (Int, Int, Int) {
  if distance <= 0 {
    return (0, 0, 0) // should not happen
  }
  let d = distance + 3
  let nbits = log2_floor(d) - 1
  let prefix = (d >> nbits) & 1
  let offset = (2 + prefix) << nbits
  let distcode = 2 * (nbits - 1) + prefix + 16 // +16 for short codes offset
  let extra = d - offset
  (distcode, nbits, extra)
}
