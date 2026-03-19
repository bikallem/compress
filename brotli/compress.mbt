///|
/// Compresses data using the Brotli format.
/// Uses uncompressed meta-blocks at level 0, LZ77+Huffman at higher levels.
pub fn compress(data : Bytes, level? : CompressionLevel = Default) -> Bytes {
  let lvl = compression_level_to_int(level)
  let src = data[:]
  let src_len = data.length()
  match src_len {
    0 => compress_empty()
    _ if lvl == 0 || src_len < 8 => compress_uncompressed(src, src_len)
    _ => compress_lz77(src, src_len, lvl)
  }
}

///|
fn compress_empty() -> Bytes {
  let bw = BitWriter::new(8)
  bw.write_bits(0, 1) // WBITS=16
  bw.write_bits(1, 1) // ISLAST
  bw.write_bits(1, 1) // ISLASTEMPTY
  bw.to_bytes()
}

///|
fn compress_uncompressed(src : BytesView, src_len : Int) -> Bytes {
  let bw = BitWriter::new(src_len + 64)
  encode_wbits(bw, 22)
  let mut offset = 0
  while offset < src_len {
    let chunk_size = if src_len - offset < MAX_METABLOCK_SIZE {
      src_len - offset
    } else {
      MAX_METABLOCK_SIZE
    }
    // All uncompressed chunks are ISLAST=0 (the decoder only reads
    // ISUNCOMPRESSED for non-last metablocks)
    bw.write_bits(0, 1) // ISLAST=0
    let (mnibbles, _) = meta_block_nibbles(chunk_size)
    bw.write_bits(mnibbles - 4, 2)
    bw.write_bits(chunk_size - 1, mnibbles * 4)
    bw.write_bits(1, 1) // ISUNCOMPRESSED=1
    if bw.n_bits > 0 {
      bw.write_bits(0, 8 - bw.n_bits)
    }
    // Bulk copy bytes directly into the BitWriter buffer
    bw.flush_final() // ensure bit buffer is fully flushed
    bw.ensure_capacity(chunk_size)
    @blit.blit_bytesview(bw.buf, bw.pos, src, offset, chunk_size)
    bw.pos += chunk_size
    offset += chunk_size
  }
  // Trailing empty last metablock
  bw.write_bits(1, 1) // ISLAST
  bw.write_bits(1, 1) // ISLASTEMPTY
  bw.to_bytes()
}

///|
priv struct BrotliCmd {
  insert_pos : Int
  insert_len : Int
  copy_len : Int
  distance : Int
}

///|
///|
/// Maximum metablock size (RFC 7932: 2^24 = 16MB).
const MAX_METABLOCK_SIZE : Int = 1 << 24

///|
fn compress_lz77(src : BytesView, src_len : Int, level : Int) -> Bytes {
  // For data larger than max metablock size, split into independent chunks.
  // Each chunk is compressed separately as its own metablock.
  if src_len > MAX_METABLOCK_SIZE {
    return compress_lz77_chunked(src, src_len)
  }
  let wbits = optimal_wbits(src_len)
  let cmds = if level <= 1 {
    lz77_find_matches(src, src_len)
  } else {
    lz77_find_matches_chain(src, src_len, level)
  }
  let compressed = encode_compressed_metablock(src, src_len, cmds, level, wbits)
  // For levels > 1, also try level 1 encoding (no context modeling, simpler
  // Huffman trees) and pick the smaller result. Context modeling overhead
  // can exceed savings on highly repetitive data.
  let compressed = if level > 1 {
    let fast_cmds = lz77_find_matches(src, src_len)
    let fast = encode_compressed_metablock(src, src_len, fast_cmds, 1, wbits)
    if fast.length() < compressed.length() { fast } else { compressed }
  } else {
    compressed
  }
  // If compressed is not smaller than uncompressed encoding, fall back.
  // Compute actual uncompressed encoding size:
  //   WBITS (4 bits) + per-chunk overhead + data + trailing empty block (2 bits)
  let uncompressed = compress_uncompressed(src, src_len)
  if compressed.length() >= uncompressed.length() {
    return uncompressed
  }
  compressed
}

///|
/// Compress large data by splitting into independently-compressed metablocks.
fn compress_lz77_chunked(src : BytesView, src_len : Int) -> Bytes {
  let wbits = optimal_wbits(src_len)
  let bw = BitWriter::new(1048576)
  encode_wbits(bw, wbits)
  let mut offset = 0
  while offset < src_len {
    let chunk_size = if src_len - offset < MAX_METABLOCK_SIZE {
      src_len - offset
    } else {
      MAX_METABLOCK_SIZE
    }
    let is_last = offset + chunk_size >= src_len
    let chunk = src[offset : offset + chunk_size]
    let cmds = lz77_find_matches(chunk, chunk_size)
    encode_metablock_into(bw, chunk, chunk_size, cmds, 1, is_last)
    offset += chunk_size
  }
  let compressed = bw.to_bytes()
  let uncompressed = compress_uncompressed(src, src_len)
  if compressed.length() >= uncompressed.length() {
    uncompressed
  } else {
    compressed
  }
}

// ─── LZ77 match finder ──────────────────────────────────────────────

///|
fn lz77_find_matches(src : BytesView, src_len : Int) -> Array[BrotliCmd] {
  let cmds : Array[BrotliCmd] = []
  if src_len < MIN_MATCH_LENGTH {
    cmds.push({ insert_pos: 0, insert_len: src_len, copy_len: 0, distance: 0 })
    return cmds
  }
  let hash_table : FixedArray[Int] = FixedArray::make(BROTLI_HASH_SIZE, -1)
  let mut pos = 0
  let mut insert_start = 0
  let max_distance = MAX_BACKWARD_DISTANCE
  while pos + 3 < src_len {
    let h = brotli_hash4(src, pos)
    let match_pos = hash_table[h]
    hash_table[h] = pos
    if match_pos >= 0 && pos - match_pos <= max_distance && pos - match_pos > 0 {
      let max_len = if src_len - pos < MAX_MATCH_LENGTH { src_len - pos } else { MAX_MATCH_LENGTH }
      let mlen = count_match(src, pos, match_pos, max_len)
      if mlen >= MIN_MATCH_LENGTH {
        let insert_len = pos - insert_start
        let dist = pos - match_pos
        cmds.push({
          insert_pos: insert_start,
          insert_len,
          copy_len: mlen,
          distance: dist,
        })
        let match_end = if pos + mlen < src_len - 3 {
          pos + mlen
        } else {
          src_len - 4
        }
        // Cap rehash: for long matches, only hash a few positions near boundaries
        let rehash_limit = if mlen > 32 { 4 } else { mlen }
        let rehash_end = if pos + rehash_limit < match_end {
          pos + rehash_limit
        } else {
          match_end
        }
        for i = pos + 1; i <= rehash_end; i = i + 1 {
          hash_table[brotli_hash4(src, i)] = i
        }
        pos += mlen
        insert_start = pos
        continue
      }
    }
    pos += 1
  }
  if insert_start < src_len {
    cmds.push({
      insert_pos: insert_start,
      insert_len: src_len - insert_start,
      copy_len: 0,
      distance: 0,
    })
  }
  cmds
}

///|
fn brotli_hash4(src : BytesView, pos : Int) -> Int {
  let v = src[pos].to_int() |
    (src[pos + 1].to_int() << 8) |
    (src[pos + 2].to_int() << 16) |
    (src[pos + 3].to_int() << 24)
  ((v & 0xFFFFFF) ^ (((v >> 16) & 0xFF) * 0x1e35a7bd)) &
  (BROTLI_HASH_SIZE - 1)
}

///|
fn count_match(src : BytesView, a : Int, b : Int, max_len : Int) -> Int {
  @blit.match_length_bv(src, a, b, max_len)
}

// ─── LZ77 hash-chain match finder (levels 2-9) ─────────────────────

///|
fn chain_depth(level : Int) -> Int {
  match level {
    0 | 1 | 2 | 3 => 8
    4 | 5 => 16
    6 | 7 => 32
    8 | 9 | 10 | 11 => 64
    _ => 64 // unreachable: level is clamped to 0-11
  }
}

///|
fn lz77_find_matches_chain(
  src : BytesView,
  src_len : Int,
  level : Int,
) -> Array[BrotliCmd] {
  let cmds : Array[BrotliCmd] = []
  if src_len < MIN_MATCH_LENGTH {
    cmds.push({ insert_pos: 0, insert_len: src_len, copy_len: 0, distance: 0 })
    return cmds
  }
  let max_chain = chain_depth(level)
  let use_lazy = level >= 4
  // For levels <= 9, cap rehash to a few positions for long matches.
  // This avoids O(match_len) hash insertions for each long match, trading
  // minor compression ratio for major speed gains on repetitive data.
  let rehash_cap = if level <= 9 { 4 } else { MAX_MATCH_LENGTH }
  let hash_size = BROTLI_HASH_SIZE
  let hash_mask = hash_size - 1
  // head[h] = most recent position with hash h, -1 if none
  let head : FixedArray[Int] = FixedArray::make(hash_size, -1)
  // prev[pos & mask] = previous position in chain with same hash
  // Size to min(src_len, MAX_BACKWARD_DISTANCE) to avoid wasteful allocation for small inputs
  let prev_size = if src_len < MAX_BACKWARD_DISTANCE {
    // Round up to next power of 2 for efficient masking
    let mut s = 1
    while s < src_len {
      s = s << 1
    }
    s
  } else {
    MAX_BACKWARD_DISTANCE
  }
  let win_mask = prev_size - 1
  let prev : FixedArray[Int] = FixedArray::make(prev_size, -1)
  let max_distance = MAX_BACKWARD_DISTANCE
  let mut pos = 0
  let mut insert_start = 0

  // Insert a position into the hash chain
  fn insert_hash(p : Int) -> Unit {
    let h = brotli_hash4(src, p) & hash_mask
    prev[p & win_mask] = head[h]
    head[h] = p
  }

  // Find best match at position p using hash chains
  fn find_best(p : Int) -> (Int, Int) {
    // returns (match_len, distance)
    if p + 3 >= src_len {
      return (0, 0)
    }
    let h = brotli_hash4(src, p) & hash_mask
    let mut best_len = 3 // minimum match is 4, so we need > 3
    let mut best_dist = 0
    let mut candidate = head[h]
    let mut chains = 0
    let max_len = if src_len - p < MAX_MATCH_LENGTH { src_len - p } else { MAX_MATCH_LENGTH }
    while candidate >= 0 && chains < max_chain {
      let dist = p - candidate
      if dist <= 0 || dist > max_distance {
        break
      }
      let mlen = count_match(src, p, candidate, max_len)
      if mlen > best_len {
        best_len = mlen
        best_dist = dist
        if mlen == max_len || mlen >= 32 {
          break
        }
      }
      candidate = prev[candidate & win_mask]
      chains += 1
    }
    if best_dist > 0 {
      (best_len, best_dist)
    } else {
      (0, 0)
    }
  }

  while pos + 3 < src_len {
    let (mlen, mdist) = find_best(pos)
    if mlen < MIN_MATCH_LENGTH {
      insert_hash(pos)
      pos += 1
      continue
    }
    // Lazy matching: check if next position has a strictly better match
    if use_lazy && pos + 4 < src_len {
      // Tentatively insert current pos so next position can chain through it
      insert_hash(pos)
      let (mlen2, mdist2) = find_best(pos + 1)
      if mlen2 > mlen + 1 {
        // Skip current position, emit next match instead
        pos += 1
        // Insert pos into chain and emit match at pos
        insert_hash(pos)
        let insert_len = pos - insert_start
        cmds.push({
          insert_pos: insert_start,
          insert_len,
          copy_len: mlen2,
          distance: mdist2,
        })
        // Insert positions near match boundaries into hash chains
        let match_end2 = if pos + mlen2 < src_len - 3 {
          pos + mlen2
        } else {
          src_len - 4
        }
        let rehash_end2 = if mlen2 > rehash_cap {
          if pos + rehash_cap < match_end2 { pos + rehash_cap } else { match_end2 }
        } else {
          match_end2
        }
        for i = pos + 1; i <= rehash_end2; i = i + 1 {
          insert_hash(i)
        }
        pos += mlen2
        insert_start = pos
        continue
      }
      // Current match is good enough, emit it
      // (pos was already inserted above)
      let insert_len = pos - insert_start
      cmds.push({
        insert_pos: insert_start,
        insert_len,
        copy_len: mlen,
        distance: mdist,
      })
      let match_end_c = if pos + mlen < src_len - 3 {
        pos + mlen
      } else {
        src_len - 4
      }
      let rehash_end_c = if mlen > rehash_cap {
        if pos + rehash_cap < match_end_c { pos + rehash_cap } else { match_end_c }
      } else {
        match_end_c
      }
      for i = pos + 1; i <= rehash_end_c; i = i + 1 {
        insert_hash(i)
      }
      pos += mlen
      insert_start = pos
      continue
    }
    // No lazy matching (levels 2-3)
    insert_hash(pos)
    let insert_len = pos - insert_start
    cmds.push({
      insert_pos: insert_start,
      insert_len,
      copy_len: mlen,
      distance: mdist,
    })
    let match_end_n = if pos + mlen < src_len - 3 {
      pos + mlen
    } else {
      src_len - 4
    }
    let rehash_end_n = if mlen > rehash_cap {
      if pos + rehash_cap < match_end_n { pos + rehash_cap } else { match_end_n }
    } else {
      match_end_n
    }
    for i = pos + 1; i <= rehash_end_n; i = i + 1 {
      insert_hash(i)
    }
    pos += mlen
    insert_start = pos
  }
  if insert_start < src_len {
    cmds.push({
      insert_pos: insert_start,
      insert_len: src_len - insert_start,
      copy_len: 0,
      distance: 0,
    })
  }
  cmds
}

// ─── Insert/copy/distance encoding ──────────────────────────────────

///|
fn encode_insert_len(insert_len : Int) -> (Int, Int, Int) {
  let code = bsearch_baselines(_insert_baselines, insert_len)
  (code, insert_len - _insert_baselines[code], _insert_extra_bits[code])
}

///|
fn encode_copy_len(copy_len : Int) -> (Int, Int, Int) {
  let code = bsearch_baselines(_copy_baselines, copy_len)
  (code, copy_len - _copy_baselines[code], _copy_extra_bits[code])
}

///|
/// Binary search for the largest index where baselines[index] <= value.
fn bsearch_baselines(baselines : FixedArray[Int], value : Int) -> Int {
  let mut lo = 0
  let mut hi = baselines.length() - 1
  while lo < hi {
    let mid = (lo + hi + 1) >> 1
    if baselines[mid] <= value {
      lo = mid
    } else {
      hi = mid - 1
    }
  }
  lo
}

///|
/// RFC 7932 Table 11 insert-and-copy combined code.
/// Codes >= 128 always require explicit distance.
fn insert_copy_combined(insert_code : Int, copy_code : Int) -> Int {
  let ic = insert_code >> 3
  let cc = copy_code >> 3
  let ir = insert_code & 7
  let cr = copy_code & 7
  let base = match (ic, cc) {
    (0, 0) => 128
    (0, 1) => 192
    (1, 0) => 256
    (1, 1) => 320
    (0, 2) => 384
    (2, 0) => 448
    (1, 2) => 512
    (2, 1) => 576
    (2, 2) => 640
    _ => 128 // unreachable: ic and cc are both 0-2
  }
  base + (ir << 3) + cr
}

///|
/// RFC 7932 Table 11 - implicit distance (codes < 128).
/// Used for insert-only trailing commands where no explicit distance is needed.
fn insert_copy_implicit(insert_code : Int, copy_code : Int) -> Int {
  let ir = insert_code & 7
  let cr = copy_code & 7
  let bits64 = cr | (ir << 3)
  if copy_code < 8 {
    bits64
  } else {
    bits64 | 64
  }
}

///|
fn encode_distance_val(distance : Int) -> (Int, Int, Int) {
  // O(1) computation using bit-scan (floor(log2)) instead of linear search.
  // For distance d, we need to find n such that:
  //   base0 = (2 << n) - 3, range = 1 << n: d in [base0, base0+range)
  //   base1 = (3 << n) - 3, range = 1 << n: d in [base1, base1+range)
  // Equivalent: n = floor(log2(distance + 3)) - 1
  let d3 = distance + 3
  let n = ilog2(d3) - 1
  if n >= 1 && n < 24 {
    let base0 = (2 << n) - 3
    let range = 1 << n
    if distance >= base0 && distance < base0 + range {
      let dextra = (n - 1) * 2
      return (16 + dextra, distance - base0, n)
    }
    let base1 = (3 << n) - 3
    if distance >= base1 && distance < base1 + range {
      let dextra = (n - 1) * 2 + 1
      return (16 + dextra, distance - base1, n)
    }
  }
  // Fallback for edge cases (distance near boundaries)
  let mut nn = 1
  while nn < 24 {
    let range = 1 << nn
    let b0 = (2 << nn) - 3
    if distance >= b0 && distance < b0 + range {
      let dextra = (nn - 1) * 2
      return (16 + dextra, distance - b0, nn)
    }
    let b1 = (3 << nn) - 3
    if distance >= b1 && distance < b1 + range {
      let dextra = (nn - 1) * 2 + 1
      return (16 + dextra, distance - b1, nn)
    }
    nn += 1
  }
  (16, distance - 1, 24)
}

///|
/// Integer log2 (floor). Returns the position of the highest set bit.
fn ilog2(v : Int) -> Int {
  let mut n = 0
  let mut x = v
  if x >= (1 << 16) { n += 16; x = x >> 16 }
  if x >= (1 << 8) { n += 8; x = x >> 8 }
  if x >= (1 << 4) { n += 4; x = x >> 4 }
  if x >= (1 << 2) { n += 2; x = x >> 2 }
  if x >= (1 << 1) { n += 1 }
  n
}

// ─── Huffman coding ─────────────────────────────────────────────────

///|
fn brotli_code_lengths(
  freqs : FixedArray[Int],
  max_bits : Int,
) -> FixedArray[Int] {
  let n = freqs.length()
  let bl = FixedArray::make(n, 0)
  let mut active = 0
  for _, f in freqs {
    if f > 0 {
      active += 1
    }
  }
  if active == 0 {
    return bl
  }
  if active == 1 {
    for i, f in freqs {
      if f > 0 {
        bl[i] = 1
        break
      }
    }
    return bl
  }
  // Retry with increasing count_limit until the tree fits in max_bits.
  // This mirrors the Go/C brotli reference encoder (createHuffmanTree).
  // When depths exceed max_bits, we inflate low frequencies and rebuild,
  // which produces a more balanced (shallower) tree.
  let mut count_limit = 1
  while count_limit < 0x7FFFFFFF {
    let sorted = FixedArray::make(active, (0, 0))
    let mut idx = 0
    for i, f in freqs {
      if f > 0 {
        let clamped = if f < count_limit { count_limit } else { f }
        sorted[idx] = (clamped, i)
        idx += 1
      }
    }
    for i in 1..<active {
      let key = sorted[i]
      let mut j = i - 1
      while j >= 0 && sorted[j].0 > key.0 {
        sorted[j + 1] = sorted[j]
        j -= 1
      }
      sorted[j + 1] = key
    }
    let leaf_freq = FixedArray::make(active, 0)
    let leaf_sym = FixedArray::make(active, 0)
    for i, entry in sorted {
      leaf_freq[i] = entry.0
      leaf_sym[i] = entry.1
    }
    let total = 2 * active - 1
    let parent = FixedArray::make(total, -1)
    let node_freq = FixedArray::make(total, 0)
    for i, f in leaf_freq {
      node_freq[i] = f
    }
    let mut lp = 0
    let mut ip = active
    let mut nn = active
    for _merge_step in 0..<(active - 1) {
      let left = if lp < active &&
        (ip >= nn || leaf_freq[lp] <= node_freq[ip]) {
        let r = lp
        lp += 1
        r
      } else {
        let r = ip
        ip += 1
        r
      }
      let right = if lp < active &&
        (ip >= nn || leaf_freq[lp] <= node_freq[ip]) {
        let r = lp
        lp += 1
        r
      } else {
        let r = ip
        ip += 1
        r
      }
      node_freq[nn] = node_freq[left] + node_freq[right]
      parent[left] = nn
      parent[right] = nn
      nn += 1
    }
    let depths = FixedArray::make(total, 0)
    for i = total - 1; i >= 0; i = i - 1 {
      if parent[i] >= 0 {
        depths[i] = depths[parent[i]] + 1
      }
    }
    for i in 0..<n {
      bl[i] = 0
    }
    let mut fits = true
    for i, sym in leaf_sym {
      bl[sym] = depths[i]
      if depths[i] > max_bits {
        fits = false
      }
    }
    if fits {
      break
    }
    // Double the count_limit and retry
    count_limit = count_limit * 2
  }
  bl
}

///|
fn brotli_build_codes(lengths : FixedArray[Int]) -> FixedArray[Int] {
  let n = lengths.length()
  let codes = FixedArray::make(n, 0)
  let mut max_len = 0
  for _, l in lengths {
    if l > max_len {
      max_len = l
    }
  }
  if max_len == 0 {
    return codes
  }
  let bl_count = FixedArray::make(max_len + 1, 0)
  for _, l in lengths {
    if l > 0 {
      bl_count[l] += 1
    }
  }
  let next_code = FixedArray::make(max_len + 1, 0)
  for bits = 1, code = 0; bits <= max_len; {
    let c = (code + bl_count[bits - 1]) << 1
    next_code[bits] = c
    continue bits + 1, c
  }
  for sym, len in lengths {
    if len > 0 {
      let c = next_code[len]
      next_code[len] += 1
      codes[sym] = (brotli_reverse(c, len) << 8) | len
    }
  }
  codes
}

///|
/// In-place insertion sort for a FixedArray[Int] (ascending).
fn sort_ints(arr : FixedArray[Int], len : Int) -> Unit {
  for i in 1..<len {
    let key = arr[i]
    let mut j = i - 1
    while j >= 0 && arr[j] > key {
      arr[j + 1] = arr[j]
      j -= 1
    }
    arr[j + 1] = key
  }
}

///|
fn brotli_reverse(val : Int, n : Int) -> Int {
  let (result, _) = for result = 0, v = val, i = 0; i < n; {
    continue (result << 1) | (v & 1), v >> 1, i + 1
  } nobreak {
    (result, val)
  }
  result
}

///|
/// Rebuild codes to match the brotli simple prefix tree structure.
/// The simple prefix tree assigns specific depths and codes based on
/// sorted symbol order, per RFC 7932 section 3.4.
fn rebuild_simple_codes(
  syms_arr : Array[Int],
  nsym : Int,
  codes : FixedArray[Int],
  code_lengths~ : FixedArray[Int] = FixedArray::make(0, 0),
) -> Unit {
  let syms = FixedArray::make(nsym, 0)
  for i in 0..<nsym {
    syms[i] = syms_arr[i]
  }
  sort_ints(syms, nsym)
  // Clear all existing codes
  for i in 0..<codes.length() {
    codes[i] = 0
  }
  // Assign codes based on simple prefix tree structure
  match nsym {
    1 => ()
      // Single symbol: 0 bits per read; codes[syms[0]] stays 0 (len=0)
    2 => {
      // 2 symbols: each 1 bit
      // sym[0] → code 0, depth 1
      // sym[1] → code 1, depth 1
      codes[syms[0]] = (0 << 8) | 1
      codes[syms[1]] = (1 << 8) | 1
    }
    3 => {
      // 3 symbols:
      // sym[0] → depth 1, code 0
      // sym[1] → depth 2, code 10 (reversed: 01)
      // sym[2] → depth 2, code 11 (reversed: 11)
      codes[syms[0]] = (0 << 8) | 1       // 0, 1 bit
      codes[syms[1]] = (1 << 8) | 2       // 01, 2 bits (reversed 10)
      codes[syms[2]] = (3 << 8) | 2       // 11, 2 bits (reversed 11)
    }
    _ => {
      // 4 symbols: depends on tree_select
      let tree_select = if code_lengths.length() > 0 &&
        syms[0] < code_lengths.length() &&
        code_lengths[syms[0]] == 1 {
        1
      } else {
        0
      }
      if tree_select == 0 {
        // All depth 2. Code assignment must match decoder's table layout:
        //   table[0]=syms[0], table[1]=syms[2], table[2]=syms[1], table[3]=syms[3]
        codes[syms[0]] = (0 << 8) | 2  // code 00
        codes[syms[1]] = (2 << 8) | 2  // code 10 (write_bits(2,2) → index 2)
        codes[syms[2]] = (1 << 8) | 2  // code 01 (write_bits(1,2) → index 1)
        codes[syms[3]] = (3 << 8) | 2  // code 11
      } else {
        // sym[0] depth 1, sym[1] depth 2, sym[2] depth 3, sym[3] depth 3
        codes[syms[0]] = (0 << 8) | 1        // 0, 1 bit
        codes[syms[1]] = (1 << 8) | 2        // 01, 2 bits (reversed 10)
        codes[syms[2]] = (3 << 8) | 3        // 011, 3 bits (reversed 110)
        codes[syms[3]] = (7 << 8) | 3        // 111, 3 bits (reversed 111)
      }
    }
  }
}


///|
fn write_symbol(bw : BitWriter, codes : FixedArray[Int], sym : Int) -> Unit {
  let entry = codes[sym]
  let len = entry & 0xFF
  let rev_code = entry >> 8
  bw.write_bits(rev_code, len)
}

// ─── Prefix code encoding ───────────────────────────────────────────

///|
fn sym_bits(alphabet_size : Int) -> Int {
  if alphabet_size <= 1 {
    return 0
  }
  let mut bits = 0
  let mut v = alphabet_size - 1
  while v > 0 {
    bits += 1
    v = v >> 1
  }
  bits
}

///|
let brotli_cl_order : FixedArray[Int] = {
  let a = FixedArray::make(18, 0)
  a[0] = 1; a[1] = 2; a[2] = 3; a[3] = 4; a[4] = 0
  a[5] = 5; a[6] = 17; a[7] = 6; a[8] = 16; a[9] = 7
  a[10] = 8; a[11] = 9; a[12] = 10; a[13] = 11
  a[14] = 12; a[15] = 13; a[16] = 14; a[17] = 15
  a
}

///|
/// Write a code-length code length using the fixed encoding from Go's brotli.
fn write_cl_length(bw : BitWriter, v : Int) -> Unit {
  match v {
    0 => bw.write_bits(0, 2)
    1 => bw.write_bits(7, 4)   // 0111
    2 => bw.write_bits(3, 3)   // 011
    3 => bw.write_bits(2, 2)   // 10
    4 => bw.write_bits(1, 2)   // 01
    5 => bw.write_bits(15, 4)  // 1111
    6 | 7 | 8 | 9 | 10 | 11 | 12 | 13 | 14 | 15 | 16 | 17 => bw.write_bits(0, 2)
    _ => bw.write_bits(0, 2) // unreachable for valid code lengths
  }
}

///|
fn encode_prefix_code(
  bw : BitWriter,
  code_lengths : FixedArray[Int],
  num_symbols : Int,
  codes : FixedArray[Int],
) -> Unit {
  let mut nsym = 0
  let syms : Array[Int] = []
  for i in 0..<num_symbols {
    if i < code_lengths.length() && code_lengths[i] > 0 {
      nsym += 1
      syms.push(i)
    }
  }
  if nsym == 0 {
    bw.write_bits(1, 2)
    bw.write_bits(0, 2)
    bw.write_bits(0, sym_bits(num_symbols))
    return
  }
  if nsym <= 4 {
    write_simple_prefix(bw, syms, nsym, num_symbols, code_lengths)
    // Rebuild codes to match the simple prefix tree structure.
    // The simple prefix tree assigns codes based on sorted symbol order,
    // not frequency.
    rebuild_simple_codes(syms, nsym, codes, code_lengths=code_lengths)
    return
  }
  write_complex_prefix(bw, code_lengths, num_symbols)
}

///|
fn write_simple_prefix(
  bw : BitWriter,
  syms_arr : Array[Int],
  nsym : Int,
  alphabet_size : Int,
  code_lengths : FixedArray[Int],
) -> Unit {
  let syms = FixedArray::make(nsym, 0)
  for i in 0..<nsym {
    syms[i] = syms_arr[i]
  }
  sort_ints(syms, nsym)
  bw.write_bits(1, 2) // simple prefix code
  bw.write_bits(nsym - 1, 2)
  let sb = sym_bits(alphabet_size)
  match nsym {
    1 => bw.write_bits(syms[0], sb)
    2 => {
      bw.write_bits(syms[0], sb)
      bw.write_bits(syms[1], sb)
    }
    3 => {
      bw.write_bits(syms[0], sb)
      bw.write_bits(syms[1], sb)
      bw.write_bits(syms[2], sb)
    }
    _ => {
      bw.write_bits(syms[0], sb)
      bw.write_bits(syms[1], sb)
      bw.write_bits(syms[2], sb)
      bw.write_bits(syms[3], sb)
      let tree_select = if code_lengths[syms[0]] == 1 { 1 } else { 0 }
      bw.write_bits(tree_select, 1)
    }
  }
}

///|
/// Encode a run of `count` zeros into cl_syms/cl_extra using code-17 with
/// proper RFC 7932 repeat accumulation semantics.
/// Consecutive code-17 symbols accumulate: repeat = (repeat-2)<<3 + delta.
/// We greedily use code-17 where possible, inserting code-0 to break the
/// chain when the accumulated formula can't represent the remaining count.
fn encode_zero_run(
  cl_syms : Array[Int],
  cl_extra : Array[Int],
  count : Int,
) -> Unit {
  let mut remaining = count
  let mut repeat = 0 // accumulated repeat state (0 = fresh)
  while remaining > 0 {
    if remaining >= 3 {
      if repeat == 0 {
        // First code-17: delta is emitted directly (no accumulation)
        let delta = if remaining > 10 { 10 } else { remaining }
        cl_syms.push(17)
        cl_extra.push(delta - 3)
        repeat = delta
        remaining -= delta
      } else {
        // Subsequent code-17: decoder computes repeat = (repeat-2)<<3 + delta
        // We need new_repeat such that new_repeat - repeat == desired_zeros
        // new_repeat = (repeat - 2) * 8 + delta, where delta in [3, 10]
        let base = (repeat - 2) * 8
        let min_new = base + 3
        let max_new = base + 10
        let min_zeros = min_new - repeat
        let max_zeros = max_new - repeat
        if remaining >= min_zeros && remaining <= max_zeros {
          // Can encode the exact remaining count
          let new_repeat = repeat + remaining
          let delta = new_repeat - base
          cl_syms.push(17)
          cl_extra.push(delta - 3)
          remaining = 0
          repeat = new_repeat
        } else if remaining >= min_zeros {
          // Emit the maximum possible zeros with one code-17
          let delta = 10
          let new_repeat = base + delta
          let zeros_emitted = new_repeat - repeat
          cl_syms.push(17)
          cl_extra.push(delta - 3)
          remaining -= zeros_emitted
          repeat = new_repeat
        } else {
          // Remaining is too small for accumulated code-17.
          // Break the chain with individual zeros, which resets repeat state.
          cl_syms.push(0)
          cl_extra.push(0)
          remaining -= 1
          repeat = 0
        }
      }
    } else {
      cl_syms.push(0)
      cl_extra.push(0)
      remaining -= 1
    }
  }
}

///|
fn write_complex_prefix(
  bw : BitWriter,
  code_lengths : FixedArray[Int],
  num_symbols : Int,
) -> Unit {
  // Find the last non-zero code length position. The decoder stops reading
  // when the Huffman code space is full, so we must not write trailing zeros
  // beyond the last non-zero entry.
  let mut rle_end = 0
  for idx in 0..<num_symbols {
    if idx < code_lengths.length() && code_lengths[idx] > 0 {
      rle_end = idx + 1
    }
  }
  // Build RLE sequence. Avoid consecutive code-16/17 to prevent accumulation.
  let cl_syms : Array[Int] = []
  let cl_extra : Array[Int] = []
  let mut i = 0
  while i < rle_end {
    let cl = if i < code_lengths.length() { code_lengths[i] } else { 0 }
    if cl == 0 {
      let mut run = 1
      while i + run < rle_end {
        let next = if i + run < code_lengths.length() {
          code_lengths[i + run]
        } else {
          0
        }
        if next != 0 {
          break
        }
        run += 1
      }
      i += run
      // Encode zero runs using code-17 (repeat 3-10 zeros) with proper
      // RFC 7932 Section 3.5 repeat accumulation.
      // Consecutive code-17 symbols accumulate: repeat = (repeat-2)<<3 + delta.
      // After each code-17, we track the accumulated repeat state to compute
      // the correct extra value for the next code-17.
      encode_zero_run(cl_syms, cl_extra, run)
    } else {
      cl_syms.push(cl)
      cl_extra.push(0)
      i += 1
      let mut run = 0
      while i + run < rle_end {
        let next = if i + run < code_lengths.length() {
          code_lengths[i + run]
        } else {
          0
        }
        if next != cl {
          break
        }
        run += 1
      }
      if run >= 3 {
        let count = if run > 6 { 6 } else { run }
        cl_syms.push(16)
        cl_extra.push(count - 3)
        run -= count
        i += count
      }
      while run > 0 {
        cl_syms.push(cl)
        cl_extra.push(0)
        run -= 1
        i += 1
      }
    }
  }
  let cl_freqs = FixedArray::make(18, 0)
  for _, s in cl_syms {
    cl_freqs[s] += 1
  }
  let cl_lens = brotli_code_lengths(cl_freqs, 5)
  // Determine HSKIP: skip leading zero CL-CL entries to save bits.
  // HSKIP=2 skips positions 0-1, HSKIP=3 skips positions 0-2.
  // (HSKIP=1 means simple prefix code, not used here.)
  let hskip = if cl_lens[brotli_cl_order[0]] == 0 &&
    cl_lens[brotli_cl_order[1]] == 0 &&
    cl_lens[brotli_cl_order[2]] == 0 {
    3
  } else if cl_lens[brotli_cl_order[0]] == 0 &&
    cl_lens[brotli_cl_order[1]] == 0 {
    2
  } else {
    0
  }
  bw.write_bits(hskip, 2)
  let mut space = 32
  let mut num_codes = 0
  for j in hskip..<18 {
    if num_codes >= 2 && space == 0 {
      break
    }
    let sym = brotli_cl_order[j]
    let cl = cl_lens[sym]
    write_cl_length(bw, cl)
    if cl > 0 {
      space -= 32 >> cl
      num_codes += 1
    }
  }
  // When there is only one non-zero CL code-length, the decoder builds a
  // Huffman table where that symbol has depth 0 (always selected, 0 bits).
  // Match this by setting depth to 0 before building codes for RLE output.
  if num_codes == 1 {
    for j in 0..<18 {
      if cl_lens[j] > 0 {
        cl_lens[j] = 0
        break
      }
    }
  }
  let cl_codes = brotli_build_codes(cl_lens)
  for j in 0..<cl_syms.length() {
    let sym = cl_syms[j]
    write_symbol(bw, cl_codes, sym)
    if sym == 16 {
      bw.write_bits(cl_extra[j], 2)
    } else if sym == 17 {
      bw.write_bits(cl_extra[j], 3)
    }
  }
}

// ─── Meta-block encoder ─────────────────────────────────────────────

///|
priv struct EncodedCommands {
  iac : FixedArray[Int] // insert-and-copy codes
  iev : FixedArray[Int] // insert extra values
  ieb : FixedArray[Int] // insert extra bits count
  cev : FixedArray[Int] // copy extra values
  ceb : FixedArray[Int] // copy extra bits count
  dc : FixedArray[Int] // distance codes (-1 = none)
  dev : FixedArray[Int] // distance extra values
  deb : FixedArray[Int] // distance extra bits count
  count : Int
  max_iac : Int
  max_dist : Int
}

///|
fn precompute_commands(cmds : Array[BrotliCmd]) -> EncodedCommands {
  let mut max_iac = 0
  let mut max_dist = 0
  let cap = cmds.length()
  let cmd_iac = FixedArray::make(cap, 0)
  let cmd_iev = FixedArray::make(cap, 0)
  let cmd_ieb = FixedArray::make(cap, 0)
  let cmd_cev = FixedArray::make(cap, 0)
  let cmd_ceb = FixedArray::make(cap, 0)
  let cmd_dc = FixedArray::make(cap, 0)
  let cmd_dev = FixedArray::make(cap, 0)
  let cmd_deb = FixedArray::make(cap, 0)
  let mut ci = 0
  let mut last_distance = 0
  for cmd in cmds {
    if cmd.copy_len > 0 {
      let (ic, iev, ieb) = encode_insert_len(cmd.insert_len)
      let (cc, cev, ceb) = encode_copy_len(cmd.copy_len)
      // Use implicit distance (IAC codes 0-127) when the distance matches
      // the last used distance. Implicit codes only support insert_code < 8
      // and copy_code < 16 (per RFC 7932 Table 11).
      let use_implicit = cmd.distance == last_distance &&
        last_distance > 0 &&
        ic < 8 &&
        cc < 16
      let iac = if use_implicit {
        insert_copy_implicit(ic, cc)
      } else {
        insert_copy_combined(ic, cc)
      }
      if use_implicit {
        if iac > max_iac {
          max_iac = iac
        }
        cmd_iac[ci] = iac
        cmd_iev[ci] = iev
        cmd_ieb[ci] = ieb
        cmd_cev[ci] = cev
        cmd_ceb[ci] = ceb
        cmd_dc[ci] = -1
        cmd_dev[ci] = 0
        cmd_deb[ci] = 0
      } else {
        let (dc, dev, deb) = encode_distance_val(cmd.distance)
        if iac > max_iac {
          max_iac = iac
        }
        if dc > max_dist {
          max_dist = dc
        }
        cmd_iac[ci] = iac
        cmd_iev[ci] = iev
        cmd_ieb[ci] = ieb
        cmd_cev[ci] = cev
        cmd_ceb[ci] = ceb
        cmd_dc[ci] = dc
        cmd_dev[ci] = dev
        cmd_deb[ci] = deb
        last_distance = cmd.distance
      }
      ci += 1
    } else if cmd.insert_len > 0 {
      let (ic, iev, ieb) = encode_insert_len(cmd.insert_len)
      let cc = 0
      if ic < 8 {
        let iac = insert_copy_implicit(ic, cc)
        if iac > max_iac {
          max_iac = iac
        }
        cmd_iac[ci] = iac
        cmd_iev[ci] = iev
        cmd_ieb[ci] = ieb
        cmd_dc[ci] = -1
        ci += 1
      } else {
        let iac = insert_copy_combined(ic, cc)
        if iac > max_iac {
          max_iac = iac
        }
        cmd_iac[ci] = iac
        cmd_iev[ci] = iev
        cmd_ieb[ci] = ieb
        cmd_dc[ci] = -1 // No distance for insert-only commands
        ci += 1
      }
    }
  }
  {
    iac: cmd_iac,
    iev: cmd_iev,
    ieb: cmd_ieb,
    cev: cmd_cev,
    ceb: cmd_ceb,
    dc: cmd_dc,
    dev: cmd_dev,
    deb: cmd_deb,
    count: ci,
    max_iac,
    max_dist,
  }
}

///|
fn encode_compressed_metablock(
  src : BytesView,
  src_len : Int,
  cmds : Array[BrotliCmd],
  level : Int,
  wbits : Int,
) -> Bytes {
  let bw = BitWriter::new(if src_len < 1048576 { src_len * 2 + 256 } else { 1048576 })
  encode_wbits(bw, wbits)
  encode_metablock_into(bw, src, src_len, cmds, level, true)
  bw.to_bytes()
}

///|
fn encode_metablock_into(
  bw : BitWriter,
  src : BytesView,
  src_len : Int,
  cmds : Array[BrotliCmd],
  level : Int,
  is_last : Bool,
) -> Unit {
  bw.write_bits(if is_last { 1 } else { 0 }, 1) // ISLAST
  if is_last {
    bw.write_bits(0, 1) // ISLASTEMPTY=0
  }
  let (mnibbles, _) = meta_block_nibbles(src_len)
  bw.write_bits(mnibbles - 4, 2)
  bw.write_bits(src_len - 1, mnibbles * 4)
  if not(is_last) {
    bw.write_bits(0, 1) // ISUNCOMPRESSED=0 (only present for non-last)
  }

  // Pre-encode commands (insert/copy/distance codes)
  let ec = precompute_commands(cmds)

  let iac_size = ec.max_iac + 1
  let dist_size = ec.max_dist + 1
  let iac_freqs = FixedArray::make(iac_size, 0)
  let dist_freqs = FixedArray::make(dist_size, 0)

  for i in 0..<ec.count {
    iac_freqs[ec.iac[i]] += 1
  }
  for i in 0..<ec.count {
    let dc = ec.dc[i]
    if dc >= 0 && dc < dist_size {
      dist_freqs[dc] += 1
    }
  }

  // Decide whether to use context modeling
  let use_context = level >= 5 && src_len >= 256

  // Compute context map and per-tree literal histograms
  let (ntreesl, cmap, tree_freqs) = build_context_model(
    src, cmds, use_context,
  )

  // ---- Write meta-block header in correct RFC 7932 order ----

  bw.write_bits(0, 1) // NBLTYPESL=1
  bw.write_bits(0, 1) // NBLTYPESI=1
  bw.write_bits(0, 1) // NBLTYPESD=1
  bw.write_bits(0, 2) // NPOSTFIX=0
  bw.write_bits(0, 4) // NDIRECT=0
  bw.write_bits(0, 2) // Context mode LSB6 (mode 0) for block type 0

  // NTREESL (VarLenUint8)
  if ntreesl == 1 {
    bw.write_bits(0, 1)
  } else {
    bw.write_bits(1, 1) // nonzero flag
    bw.write_bits(0, 3) // nbits=0 → value=1 → NTREESL=2
  }

  // Context map for literals (only if NTREESL >= 2)
  if ntreesl >= 2 {
    encode_context_map(bw, cmap)
  }

  // NTREESD=1
  bw.write_bits(0, 1)

  // Write prefix codes: NTREESL literal trees, then IAC, then distance
  let lit_codes_arr : Array[FixedArray[Int]] = []
  for t in 0..<ntreesl {
    let lengths = brotli_code_lengths(tree_freqs[t], 15)
    let codes = brotli_build_codes(lengths)
    encode_prefix_code(bw, lengths, 256, codes)
    lit_codes_arr.push(codes)
  }

  let iac_lengths = brotli_code_lengths(iac_freqs, 15)
  let iac_codes = brotli_build_codes(iac_lengths)
  let dist_lengths = brotli_code_lengths(dist_freqs, 15)
  let dist_codes = brotli_build_codes(dist_lengths)
  let dist_alphabet = 16 + 48
  encode_prefix_code(bw, iac_lengths, 704, iac_codes)
  encode_prefix_code(bw, dist_lengths, dist_alphabet, dist_codes)

  // Write command data
  let mut ci = 0
  for cmd in cmds {
    if ci >= ec.count {
      break
    }
    let iac_entry = iac_codes[ec.iac[ci]]
    bw.write_bits(iac_entry >> 8, iac_entry & 0xFF)
    if ec.ieb[ci] > 0 {
      bw.write_bits(ec.iev[ci], ec.ieb[ci])
    }
    if ec.ceb[ci] > 0 {
      bw.write_bits(ec.cev[ci], ec.ceb[ci])
    }
    if ntreesl > 1 {
      for j in 0..<cmd.insert_len {
        let pos = cmd.insert_pos + j
        let p1 = if pos > 0 { src[pos - 1].to_int() } else { 0 }
        let ctx = p1 & (NUM_LITERAL_CONTEXTS - 1)
        let tree_idx = cmap[ctx]
        let codes = lit_codes_arr[tree_idx]
        let entry = codes[src[pos].to_int()]
        bw.write_bits(entry >> 8, entry & 0xFF)
      }
    } else {
      let codes = lit_codes_arr[0]
      for j in 0..<cmd.insert_len {
        let entry = codes[src[cmd.insert_pos + j].to_int()]
        bw.write_bits(entry >> 8, entry & 0xFF)
      }
    }
    if ec.dc[ci] >= 0 {
      let dist_entry = dist_codes[ec.dc[ci]]
      bw.write_bits(dist_entry >> 8, dist_entry & 0xFF)
      if ec.deb[ci] > 0 {
        bw.write_bits(ec.dev[ci], ec.deb[ci])
      }
    }
    ci += 1
  }
}

///|
/// Build context model for literals. Returns (ntreesl, context_map, tree_freqs).
fn build_context_model(
  src : BytesView,
  cmds : Array[BrotliCmd],
  use_context : Bool,
) -> (Int, FixedArray[Int], Array[FixedArray[Int]]) {
  if not(use_context) {
    let lit_freqs = FixedArray::make(256, 0)
    for cmd in cmds {
      for j in 0..<cmd.insert_len {
        lit_freqs[src[cmd.insert_pos + j].to_int()] += 1
      }
    }
    return (1, FixedArray::make(64, 0), [lit_freqs])
  }

  // Build per-context literal histograms (64 contexts for LSB6 mode)
  let ctx_hists : FixedArray[FixedArray[Int]] = FixedArray::make(
    64,
    FixedArray::make(0, 0),
  )
  for i in 0..<64 {
    ctx_hists[i] = FixedArray::make(256, 0)
  }
  for cmd in cmds {
    for j in 0..<cmd.insert_len {
      let pos = cmd.insert_pos + j
      let p1 = if pos > 0 { src[pos - 1].to_int() } else { 0 }
      let ctx = p1 & (NUM_LITERAL_CONTEXTS - 1)
      ctx_hists[ctx][src[pos].to_int()] += 1
    }
  }

  // Cluster 64 contexts into 2 groups
  let cmap = cluster_contexts(ctx_hists, 2)

  // Build per-tree histograms directly from ctx_hists + cmap
  // (avoids re-scanning all commands/literals)
  let tree_freqs : Array[FixedArray[Int]] = [
    FixedArray::make(256, 0),
    FixedArray::make(256, 0),
  ]
  let mut has_tree0 = false
  let mut has_tree1 = false
  for ctx in 0..<64 {
    let tree_idx = cmap[ctx]
    let hist = ctx_hists[ctx]
    let dst = tree_freqs[tree_idx]
    for sym in 0..<256 {
      if hist[sym] > 0 {
        dst[sym] += hist[sym]
        if tree_idx == 0 {
          has_tree0 = true
        } else {
          has_tree1 = true
        }
      }
    }
  }

  if not(has_tree0 && has_tree1) {
    // All contexts map to one tree; fall back to single tree
    // Merge both tree_freqs into one
    let lit_freqs = tree_freqs[0]
    let other = tree_freqs[1]
    for sym in 0..<256 {
      lit_freqs[sym] += other[sym]
    }
    return (1, FixedArray::make(64, 0), [lit_freqs])
  }

  (2, cmap, tree_freqs)
}

///|
/// Cluster 64 context histograms into num_clusters groups.
/// Returns a context map (64 entries, each mapping to a cluster index 0..num_clusters-1).
fn cluster_contexts(
  ctx_hists : FixedArray[FixedArray[Int]],
  num_clusters : Int,
) -> FixedArray[Int] {
  let n = 64
  // cluster_id[i] = which cluster context i belongs to
  let cluster_id = FixedArray::make(n, 0)
  for i in 0..<n {
    cluster_id[i] = i
  }
  // Merged histogram per cluster
  let merged : Array[FixedArray[Int]] = []
  for i in 0..<n {
    let h = FixedArray::make(256, 0)
    for j in 0..<256 {
      h[j] = ctx_hists[i][j]
    }
    merged.push(h)
  }
  // Total count per cluster
  let counts = FixedArray::make(n, 0)
  for i in 0..<n {
    let mut total = 0
    for j in 0..<256 {
      total += ctx_hists[i][j]
    }
    counts[i] = total
  }
  // alive[i] = true if cluster i still exists
  let alive = FixedArray::make(n, true)
  let mut num_alive = n

  // Greedily merge the two most similar clusters until we have num_clusters
  while num_alive > num_clusters {
    // Find the pair with minimum merge cost
    let mut best_a = -1
    let mut best_b = -1
    let mut best_cost = 0x7fffffff // large value

    // For efficiency, find the two smallest clusters to merge
    // (simplification: merge the two clusters with smallest combined count)
    for i in 0..<n {
      if not(alive[i]) {
        continue
      }
      for j in (i + 1)..<n {
        if not(alive[j]) {
          continue
        }
        let cost = counts[i] + counts[j]
        if cost < best_cost {
          best_cost = cost
          best_a = i
          best_b = j
        }
      }
    }
    if best_a < 0 {
      break
    }
    // Merge cluster best_b into best_a
    for j in 0..<256 {
      merged[best_a][j] += merged[best_b][j]
    }
    counts[best_a] += counts[best_b]
    alive[best_b] = false
    // Reassign all contexts from best_b to best_a
    for i in 0..<n {
      if cluster_id[i] == best_b {
        cluster_id[i] = best_a
      }
    }
    num_alive -= 1
  }
  // Renumber clusters to 0..num_clusters-1
  let remap = FixedArray::make(n, 0)
  let mut next_id = 0
  for i in 0..<n {
    if alive[i] {
      remap[i] = next_id
      next_id += 1
    }
  }
  let result = FixedArray::make(n, 0)
  for i in 0..<n {
    result[i] = remap[cluster_id[i]]
  }
  result
}

///|
/// Encode a context map (RFC 7932 Section 7.3).
/// Writes the map entries using a simple prefix code without RLE.
fn encode_context_map(bw : BitWriter, cmap : FixedArray[Int]) -> Unit {
  let map_size = cmap.length()
  // Find max value in map to determine num_trees
  let mut max_val = 0
  for _, v in cmap {
    if v > max_val {
      max_val = v
    }
  }
  let num_trees = max_val + 1

  // RLEMAX = 0 (no run-length encoding for zeros)
  bw.write_bits(0, 1)

  // Alphabet size = RLEMAX + num_trees = 0 + num_trees = num_trees
  // Build histogram and prefix code for context map entries
  let cm_freqs = FixedArray::make(num_trees, 0)
  for _, v in cmap {
    cm_freqs[v] += 1
  }
  let cm_lengths = brotli_code_lengths(cm_freqs, 15)
  let cm_codes = brotli_build_codes(cm_lengths)
  encode_prefix_code(bw, cm_lengths, num_trees, cm_codes)

  // Write the context map entries
  for i in 0..<map_size {
    write_symbol(bw, cm_codes, cmap[i])
  }

  // IMTF = 0 (no inverse move-to-front)
  bw.write_bits(0, 1)
}

// ─── Utility ────────────────────────────────────────────────────────

///|
/// Choose the smallest WBITS value that can represent the input size,
/// preferring encodings with shorter headers. WBITS=16 uses 1 bit,
/// WBITS 18-24 use 4 bits, WBITS 10-15/17 use 7 bits.
fn optimal_wbits(src_len : Int) -> Int {
  // WBITS=16 (1 bit header, 64KB window) — best for small inputs
  if src_len <= (1 << 16) {
    16
  } else if src_len <= (1 << 17) {
    // WBITS=17 costs 7 bits; WBITS=18 costs 4 bits — use 18 to save 3 header bits
    18
  } else if src_len <= (1 << 18) {
    18
  } else if src_len <= (1 << 19) {
    19
  } else if src_len <= (1 << 20) {
    20
  } else if src_len <= (1 << 21) {
    21
  } else if src_len <= (1 << 22) {
    22
  } else if src_len <= (1 << 23) {
    23
  } else {
    24
  }
}

///|
fn encode_wbits(bw : BitWriter, wbits : Int) -> Unit {
  match wbits {
    16 => bw.write_bits(0, 1)
    17 => bw.write_bits(0b0000001, 7)
    10 => bw.write_bits(0b0100001, 7)
    11 => bw.write_bits(0b0110001, 7)
    12 => bw.write_bits(0b1000001, 7)
    13 => bw.write_bits(0b1010001, 7)
    14 => bw.write_bits(0b1100001, 7)
    15 => bw.write_bits(0b1110001, 7)
    18 => bw.write_bits(0b0011, 4)
    19 => bw.write_bits(0b0101, 4)
    20 => bw.write_bits(0b0111, 4)
    21 => bw.write_bits(0b1001, 4)
    22 => bw.write_bits(0b1011, 4)
    23 => bw.write_bits(0b1101, 4)
    24 => bw.write_bits(0b1111, 4)
    _ => bw.write_bits(0, 1) // unreachable for valid WBITS values
  }
}

///|
fn meta_block_nibbles(mlen : Int) -> (Int, Int) {
  if mlen <= 0 {
    (4, 0)
  } else if mlen <= 1 << 16 {
    (4, mlen - 1)
  } else if mlen <= 1 << 20 {
    (5, mlen - 1)
  } else {
    (6, mlen - 1)
  }
}
