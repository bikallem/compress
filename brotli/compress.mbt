///|
/// Compresses data using the Brotli format.
/// Uses uncompressed meta-blocks at level 0, LZ77+Huffman at higher levels.
pub fn compress(data : Bytes, level? : CompressionLevel = Default) -> Bytes {
  let lvl = compression_level_to_int(level)
  let src = data[:]
  let src_len = data.length()
  if src_len == 0 {
    return compress_empty()
  }
  if lvl == 0 || src_len < 8 {
    return compress_uncompressed(src, src_len)
  }
  compress_lz77(src, src_len, lvl)
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
  let bw = BitWriter::new(src_len + 32)
  encode_wbits(bw, 22)
  bw.write_bits(0, 1) // ISLAST=0
  let (mnibbles, _) = meta_block_nibbles(src_len)
  bw.write_bits(mnibbles - 4, 2)
  bw.write_bits(src_len - 1, mnibbles * 4)
  bw.write_bits(1, 1) // ISUNCOMPRESSED=1
  if bw.n_bits > 0 {
    bw.write_bits(0, 8 - bw.n_bits)
  }
  for x in src {
    bw.write_bits(x.to_int(), 8)
  }
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
fn compress_lz77(src : BytesView, src_len : Int, _level : Int) -> Bytes {
  // Count distinct literals
  let seen = FixedArray::make(256, false)
  let mut distinct = 0
  for i in 0..<src_len {
    let b = src[i].to_int()
    if not(seen[b]) {
      seen[b] = true
      distinct += 1
    }
  }
  // Use LZ77 compression only when beneficial and reliable.
  // Currently limited to data with 1-4 distinct byte values (simple prefix codes).
  // Also limited to moderate size to avoid encoder issues with many commands.
  if distinct > 4 || src_len > 4096 {
    return compress_uncompressed(src, src_len)
  }
  ignore(distinct)
  let cmds = lz77_find_matches(src, src_len)
  encode_compressed_metablock(src, src_len, cmds)
}

// ─── LZ77 match finder ──────────────────────────────────────────────

///|
fn lz77_find_matches(src : BytesView, src_len : Int) -> Array[BrotliCmd] {
  let cmds : Array[BrotliCmd] = []
  if src_len < 4 {
    cmds.push({ insert_pos: 0, insert_len: src_len, copy_len: 0, distance: 0 })
    return cmds
  }
  let hash_table : FixedArray[Int] = FixedArray::make(BROTLI_HASH_SIZE, -1)
  let mut pos = 0
  let mut insert_start = 0
  let max_distance = 1 << 22
  while pos + 3 < src_len {
    let h = brotli_hash4(src, pos)
    let match_pos = hash_table[h]
    hash_table[h] = pos
    if match_pos >= 0 && pos - match_pos <= max_distance && pos - match_pos > 0 {
      let max_len = if src_len - pos < 258 { src_len - pos } else { 258 }
      let mlen = count_match(src, pos, match_pos, max_len)
      if mlen >= 4 {
        let insert_len = pos - insert_start
        let dist = pos - match_pos
        cmds.push({
          insert_pos: insert_start,
          insert_len,
          copy_len: mlen,
          distance: dist,
        })
        let end = if pos + mlen < src_len - 3 {
          pos + mlen
        } else {
          src_len - 4
        }
        for i = pos + 1; i <= end; i = i + 1 {
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
  let mut i = 0
  while i < max_len && src[a + i] == src[b + i] {
    i += 1
  }
  i
}

// ─── Insert/copy/distance encoding ──────────────────────────────────

///|
fn encode_insert_len(insert_len : Int) -> (Int, Int, Int) {
  let mut code = 0
  for i = 0; i < 24; i = i + 1 {
    if i == 23 || _insert_baselines[i + 1] > insert_len {
      code = i
      break
    }
  }
  (code, insert_len - _insert_baselines[code], _insert_extra_bits[code])
}

///|
fn encode_copy_len(copy_len : Int) -> (Int, Int, Int) {
  let mut code = 0
  for i = 0; i < 24; i = i + 1 {
    if i == 23 || _copy_baselines[i + 1] > copy_len {
      code = i
      break
    }
  }
  (code, copy_len - _copy_baselines[code], _copy_extra_bits[code])
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
    _ => 128
  }
  base + (ir << 3) + cr
}

///|
fn encode_distance_val(distance : Int) -> (Int, Int, Int) {
  let mut n = 1
  while n < 24 {
    let range = 1 << n
    let base0 = (2 << n) - 3
    if distance >= base0 && distance < base0 + range {
      let dextra = (n - 1) * 2
      return (16 + dextra, distance - base0, n)
    }
    let base1 = (3 << n) - 3
    if distance >= base1 && distance < base1 + range {
      let dextra = (n - 1) * 2 + 1
      return (16 + dextra, distance - base1, n)
    }
    n += 1
  }
  (16, distance - 1, 24)
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
  let sorted = FixedArray::make(active, (0, 0))
  let mut idx = 0
  for i, f in freqs {
    if f > 0 {
      sorted[idx] = (f, i)
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
  for _ in 0..<(active - 1) {
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
  for i, sym in leaf_sym {
    bl[sym] = depths[i]
  }
  let mut needs_limit = false
  for _, b in bl {
    if b > max_bits {
      needs_limit = true
      break
    }
  }
  if needs_limit {
    for i, b in bl {
      if b > max_bits {
        bl[i] = max_bits
      }
    }
    let mut kraft = 0
    for _, b in bl {
      if b > 0 {
        kraft += 1 << (max_bits - b)
      }
    }
    let target = 1 << max_bits
    while kraft > target {
      for len = 1; len < max_bits && kraft > target; len = len + 1 {
        for i in 0..<n {
          if bl[i] == len && kraft > target {
            bl[i] += 1
            kraft -= 1 << (max_bits - len - 1)
          }
        }
      }
    }
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
fn brotli_reverse(val : Int, n : Int) -> Int {
  let (result, _) = for result = 0, v = val, i = 0; i < n; {
    continue (result << 1) | (v & 1), v >> 1, i + 1
  } nobreak {
    (result, val)
  }
  result
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
    _ => bw.write_bits(0, 2)
  }
}

///|
fn encode_prefix_code(
  bw : BitWriter,
  code_lengths : FixedArray[Int],
  num_symbols : Int,
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
  for i in 1..<nsym {
    let key = syms[i]
    let mut j = i - 1
    while j >= 0 && syms[j] > key {
      syms[j + 1] = syms[j]
      j -= 1
    }
    syms[j + 1] = key
  }
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
fn write_complex_prefix(
  bw : BitWriter,
  code_lengths : FixedArray[Int],
  num_symbols : Int,
) -> Unit {
  // Build RLE sequence. Avoid consecutive code-16/17 to prevent accumulation.
  let cl_syms : Array[Int] = []
  let cl_extra : Array[Int] = []
  let mut i = 0
  while i < num_symbols {
    let cl = if i < code_lengths.length() { code_lengths[i] } else { 0 }
    if cl == 0 {
      let mut run = 1
      while i + run < num_symbols {
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
      if run >= 3 {
        let count = if run > 10 { 10 } else { run }
        cl_syms.push(17)
        cl_extra.push(count - 3)
        run -= count
      }
      while run > 0 {
        cl_syms.push(0)
        cl_extra.push(0)
        run -= 1
      }
    } else {
      cl_syms.push(cl)
      cl_extra.push(0)
      i += 1
      let mut run = 0
      while i + run < num_symbols {
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
  bw.write_bits(0, 2) // HSKIP=0
  let mut space = 32
  let mut num_codes = 0
  for j in 0..<18 {
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
fn encode_compressed_metablock(
  src : BytesView,
  src_len : Int,
  cmds : Array[BrotliCmd],
) -> Bytes {
  let bw = BitWriter::new(src_len * 2 + 256)
  encode_wbits(bw, 22)
  bw.write_bits(1, 1) // ISLAST=1
  bw.write_bits(0, 1) // ISLASTEMPTY=0
  let (mnibbles, _) = meta_block_nibbles(src_len)
  bw.write_bits(mnibbles - 4, 2)
  bw.write_bits(src_len - 1, mnibbles * 4)

  bw.write_bits(0, 1) // NBLTYPESL=1
  bw.write_bits(0, 1) // NBLTYPESI=1
  bw.write_bits(0, 1) // NBLTYPESD=1
  bw.write_bits(0, 2) // NPOSTFIX=0
  bw.write_bits(0, 4) // NDIRECT=0
  bw.write_bits(0, 2) // Context mode LSB6
  bw.write_bits(0, 1) // NTREESL=1
  bw.write_bits(0, 1) // NTREESD=1

  let lit_freqs = FixedArray::make(256, 0)
  let mut max_iac = 0
  let mut max_dist = 0

  let cmd_iac : Array[Int] = []
  let cmd_iev : Array[Int] = []
  let cmd_ieb : Array[Int] = []
  let cmd_cev : Array[Int] = []
  let cmd_ceb : Array[Int] = []
  let cmd_dc : Array[Int] = []
  let cmd_dev : Array[Int] = []
  let cmd_deb : Array[Int] = []

  for cmd in cmds {
    for j in 0..<cmd.insert_len {
      lit_freqs[src[cmd.insert_pos + j].to_int()] += 1
    }
    if cmd.copy_len > 0 {
      let (ic, iev, ieb) = encode_insert_len(cmd.insert_len)
      let (cc, cev, ceb) = encode_copy_len(cmd.copy_len)
      let iac = insert_copy_combined(ic, cc)
      let (dc, dev, deb) = encode_distance_val(cmd.distance)
      if iac > max_iac {
        max_iac = iac
      }
      if dc > max_dist {
        max_dist = dc
      }
      cmd_iac.push(iac)
      cmd_iev.push(iev)
      cmd_ieb.push(ieb)
      cmd_cev.push(cev)
      cmd_ceb.push(ceb)
      cmd_dc.push(dc)
      cmd_dev.push(dev)
      cmd_deb.push(deb)
    } else if cmd.insert_len > 0 {
      let (ic, iev, ieb) = encode_insert_len(cmd.insert_len)
      let cc = 0
      let iac = insert_copy_combined(ic, cc)
      if iac > max_iac {
        max_iac = iac
      }
      if 16 > max_dist {
        max_dist = 16
      }
      cmd_iac.push(iac)
      cmd_iev.push(iev)
      cmd_ieb.push(ieb)
      cmd_cev.push(0)
      cmd_ceb.push(0)
      cmd_dc.push(16)
      cmd_dev.push(0)
      cmd_deb.push(1)
    }
  }

  let iac_size = max_iac + 1
  let dist_size = max_dist + 1
  let iac_freqs = FixedArray::make(iac_size, 0)
  let dist_freqs = FixedArray::make(dist_size, 0)

  for _, iac in cmd_iac {
    iac_freqs[iac] += 1
  }
  for _, dc in cmd_dc {
    if dc < dist_size {
      dist_freqs[dc] += 1
    }
  }

  let lit_lengths = brotli_code_lengths(lit_freqs, 15)
  let lit_codes = brotli_build_codes(lit_lengths)
  let iac_lengths = brotli_code_lengths(iac_freqs, 15)
  let iac_codes = brotli_build_codes(iac_lengths)
  let dist_lengths = brotli_code_lengths(dist_freqs, 15)
  let dist_codes = brotli_build_codes(dist_lengths)

  let dist_alphabet = 16 + 48
  encode_prefix_code(bw, lit_lengths, 256)
  encode_prefix_code(bw, iac_lengths, 704)
  encode_prefix_code(bw, dist_lengths, dist_alphabet)

  let mut ci = 0
  for cmd in cmds {
    if ci >= cmd_iac.length() {
      break
    }
    write_symbol(bw, iac_codes, cmd_iac[ci])
    if cmd_ieb[ci] > 0 {
      bw.write_bits(cmd_iev[ci], cmd_ieb[ci])
    }
    if cmd_ceb[ci] > 0 {
      bw.write_bits(cmd_cev[ci], cmd_ceb[ci])
    }
    for j in 0..<cmd.insert_len {
      write_symbol(bw, lit_codes, src[cmd.insert_pos + j].to_int())
    }
    write_symbol(bw, dist_codes, cmd_dc[ci])
    if cmd_deb[ci] > 0 {
      bw.write_bits(cmd_dev[ci], cmd_deb[ci])
    }
    ci += 1
  }
  bw.to_bytes()
}

// ─── Utility ────────────────────────────────────────────────────────

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
    _ => bw.write_bits(0, 1)
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
