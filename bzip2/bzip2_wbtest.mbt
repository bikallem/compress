///|
fn bzip2_compress_randomized_for_test(
  data : Bytes,
  level? : Int = 9,
) -> Bytes raise Bzip2Error {
  guard level >= 1 && level <= 9 else {
    raise Bzip2Error::CorruptData("invalid bzip2 level: must be 1-9")
  }
  let bw = Bzip2BitWriter::new(size_hint=data.length())
  bw.write_byte(BZIP2_MAGIC1)
  bw.write_byte(BZIP2_MAGIC2)
  bw.write_byte(b'h')
  bw.write_byte((b'0'.to_int() + level).to_byte())
  let block_size = level * 100000
  let mut stream_crc = 0U
  let mut offset = 0
  while offset < data.length() {
    let end = if offset + block_size < data.length() {
      offset + block_size
    } else {
      data.length()
    }
    let rle1 = rle1_encode(data, offset, end)
    let randomized = bzip2_apply_randomization(rle1)
    let (bwt_data, orig_ptr) = bwt_transform(randomized)
    let (symbols, num_in_use, in_use) = mtf_rle2_encode(bwt_data)
    let block_crc = bzip2_crc32_range(data, offset, end)
    write_block(
      bw,
      symbols,
      num_in_use,
      in_use,
      orig_ptr,
      block_crc,
      randomized=true,
    )
    stream_crc = ((stream_crc << 1) | (stream_crc >> 31)) ^ block_crc
    offset = end
  }
  bw.write_bits(0x177245U, 24)
  bw.write_bits(0x385090U, 24)
  bw.write_bits(stream_crc >> 16, 16)
  bw.write_bits(stream_crc & 0xFFFFU, 16)
  bw.flush()
  bw.to_bytes()
}

///|
test "bzip2 decompress randomized block" {
  let original = b"Randomized bzip2 block fixture repeated repeated repeated."
  let compressed = bzip2_compress_randomized_for_test(original)
  let decompressed = decompress(compressed)
  assert_eq(decompressed, original)
}

///|
fn mixed_symbol_groups_for_test() -> (Array[Int], Int) {
  let alpha_size = 18
  let eob = alpha_size - 1
  let symbols : Array[Int] = []
  for group in 0..<12 {
    let dominant = 2 + group % 4 * 3
    for i in 0..<BZIP2_GROUP_SIZE {
      let sym = if i < 38 {
        dominant + i % 2
      } else if i < 46 {
        2 + (group + i) % 12
      } else {
        eob
      }
      symbols.push(sym)
    }
  }
  symbols.push(eob)
  (symbols, alpha_size)
}

///|
fn bzip2_encoding_cost_for_test(
  symbols : Array[Int],
  selectors : Array[Int],
  trees : Array[Bzip2EncodingTree],
) -> Int {
  let mut cost = 0
  for group_idx in 0..<selectors.length() {
    let tree = trees[selectors[group_idx]]
    let start = group_idx * BZIP2_GROUP_SIZE
    let end = if start + BZIP2_GROUP_SIZE < symbols.length() {
      start + BZIP2_GROUP_SIZE
    } else {
      symbols.length()
    }
    for i in start..<end {
      cost += tree.lengths.unsafe_get(symbols[i])
    }
  }
  cost
}

///|
fn bzip2_single_tree_cost_for_test(
  symbols : Array[Int],
  alpha_size : Int,
) -> Int {
  let freqs = FixedArray::make(alpha_size, 0)
  for sym in symbols {
    freqs.unsafe_set(sym, freqs.unsafe_get(sym) + 1)
  }
  let lengths = bzip2_compute_lengths(freqs, alpha_size, BZIP2_MAX_CODE_LEN)
  let mut cost = 0
  for sym in symbols {
    cost += lengths.unsafe_get(sym)
  }
  cost
}

///|
fn mixed_block_fixture_for_test() -> Bytes {
  let buf = @blit.Buffer::new(size_hint=48000)
  for i in 0..<240 {
    let repeated = (65 + i % 26).to_byte()
    for _ in 0..<64 {
      buf.write_byte(repeated)
    }
    for j in 0..<32 {
      buf.write_byte(if ((i + j) & 1) == 0 { b'\x00' } else { b'\xFF' })
    }
    buf.write_bytes(b"the quick brown fox jumps over the lazy dog ")
    for j in 0..<48 {
      buf.write_byte(((i * 37 + j * 11) % 251).to_byte())
    }
  }
  buf.to_bytes()
}

///|
priv struct Bzip2SelectorMetadata {
  num_trees : Int
  selectors : Array[Int]
}

///|
fn bzip2_read_bits_for_test(bb : BitBuf, n : Int) -> UInt raise Bzip2Error {
  guard bb.read(n) is Some(v) else { raise Bzip2Error::UnexpectedEOF }
  v
}

///|
fn bzip2_read_bit_for_test(bb : BitBuf) -> Bool raise Bzip2Error {
  guard bb.read_bit() is Some(v) else { raise Bzip2Error::UnexpectedEOF }
  v
}

///|
fn bzip2_first_block_selector_metadata_for_test(
  data : Bytes,
) -> Bzip2SelectorMetadata raise Bzip2Error {
  guard data.length() >= 4 else { raise Bzip2Error::UnexpectedEOF }
  if data[0] != BZIP2_MAGIC1 || data[1] != BZIP2_MAGIC2 || data[2] != b'h' {
    raise Bzip2Error::InvalidHeader("invalid bzip2 stream header")
  }
  let bb = BitBuf::new()
  bb.set_input(data[4:])
  let magic_hi = bzip2_read_bits_for_test(bb, 24)
  let magic_lo = bzip2_read_bits_for_test(bb, 24)
  if magic_hi != 0x314159U || magic_lo != 0x265359U {
    raise Bzip2Error::CorruptData("expected a block header")
  }
  ignore(bzip2_read_bits_for_test(bb, 16))
  ignore(bzip2_read_bits_for_test(bb, 16))
  ignore(bzip2_read_bits_for_test(bb, 1))
  ignore(bzip2_read_bits_for_test(bb, 24))
  let used_groups = bzip2_read_bits_for_test(bb, 16)
  let mut num_in_use = 0
  for g in 0..<16 {
    if (used_groups & (1U << (15 - g))) != 0U {
      let group_bits = bzip2_read_bits_for_test(bb, 16)
      for j in 0..<16 {
        if (group_bits & (1U << (15 - j))) != 0U {
          num_in_use += 1
        }
      }
    }
  }
  if num_in_use == 0 {
    raise Bzip2Error::CorruptData("expected symbols in use")
  }
  let num_trees = bzip2_read_bits_for_test(bb, 3).reinterpret_as_int()
  let num_selectors = bzip2_read_bits_for_test(bb, 15).reinterpret_as_int()
  let selectors : Array[Int] = Array::make(num_selectors, 0)
  for i in 0..<num_selectors {
    let mut idx = 0
    while bzip2_read_bit_for_test(bb) {
      idx += 1
      if idx >= num_trees {
        raise Bzip2Error::CorruptData("invalid selector in test parser")
      }
    }
    selectors[i] = idx
  }
  let mtf = FixedArray::make(num_trees, 0)
  for i in 0..<num_trees {
    mtf.unsafe_set(i, i)
  }
  for i in 0..<num_selectors {
    let idx = selectors[i]
    let selector = mtf.unsafe_get(idx)
    for j = idx; j > 0; j = j - 1 {
      mtf.unsafe_set(j, mtf.unsafe_get(j - 1))
    }
    mtf.unsafe_set(0, selector)
    selectors[i] = selector
  }
  { num_trees, selectors }
}

///|
test "bzip2 planner reduces mixed-group Huffman cost" {
  let (symbols, alpha_size) = mixed_symbol_groups_for_test()
  let plan = build_bzip2_encoding_plan(symbols, alpha_size)
  let used = FixedArray::make(plan.num_trees, false)
  let mut distinct = 0
  for selector in plan.selectors {
    if !used.unsafe_get(selector) {
      used.unsafe_set(selector, true)
      distinct += 1
    }
  }
  let multi_cost = bzip2_encoding_cost_for_test(
    symbols,
    plan.selectors,
    plan.trees,
  )
  let single_cost = bzip2_single_tree_cost_for_test(symbols, alpha_size)
  assert_true(distinct >= 2)
  assert_true(multi_cost < single_cost)
}

///|
test "bzip2 encoder emits multiple selectors on mixed block data" {
  let original = mixed_block_fixture_for_test()
  let compressed = compress(original, level=1)
  let metadata = bzip2_first_block_selector_metadata_for_test(compressed)
  let used = FixedArray::make(metadata.num_trees, false)
  let mut distinct = 0
  for selector in metadata.selectors {
    if !used.unsafe_get(selector) {
      used.unsafe_set(selector, true)
      distinct += 1
    }
  }
  assert_true(distinct >= 2)
  assert_eq(decompress(compressed), original)
}
