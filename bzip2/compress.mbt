///|
/// Compresses data using bzip2.
/// Block size level 1-9 (default 9), where level N uses N*100000 byte blocks.
pub fn compress(data : Bytes, level? : Int = 9) -> Bytes raise Bzip2Error {
  guard level >= 1 && level <= 9 else {
    raise Bzip2Error::CorruptData("invalid bzip2 level: must be 1-9")
  }
  let bw = Bzip2BitWriter::new(size_hint=data.length())
  // Stream header: "BZh" + level
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
    // RLE1 encode
    let rle1 = rle1_encode(data, offset, end)
    // BWT
    let (bwt_data, orig_ptr) = bwt_transform(rle1)
    // MTF + RLE2
    let (symbols, num_in_use, in_use) = mtf_rle2_encode(bwt_data)
    // Block CRC (on the original block data before RLE1)
    let block_crc = bzip2_crc32_range(data, offset, end)
    stream_crc = ((stream_crc << 1) | (stream_crc >> 31)) ^ block_crc
    // Write block
    write_block(bw, symbols, num_in_use, in_use, orig_ptr, block_crc)
    offset = end
  }
  // Handle empty input
  if data.length() == 0 {
    // Write an empty block: just the EOS marker
  }
  // End of stream marker: 0x177245385090
  bw.write_bits(0x177245U, 24)
  bw.write_bits(0x385090U, 24)
  // Stream CRC
  bw.write_bits(stream_crc >> 16, 16)
  bw.write_bits(stream_crc & 0xFFFFU, 16)
  bw.flush()
  bw.to_bytes()
}

///|
/// RLE1 encode: runs of 4+ identical bytes → 4 copies + count byte
fn rle1_encode(data : Bytes, start : Int, end : Int) -> Bytes {
  let out = @buffer.new(size_hint=end - start)
  let mut i = start
  while i < end {
    let b = data[i]
    let mut run = 1
    while i + run < end && data[i + run] == b && run < 259 {
      run += 1
    }
    if run >= 4 {
      // Write 4 copies + count
      out.write_byte(b)
      out.write_byte(b)
      out.write_byte(b)
      out.write_byte(b)
      out.write_byte((run - 4).to_byte())
      i += run
    } else {
      out.write_byte(b)
      i += 1
    }
  }
  out.to_bytes()
}

///|
/// Burrows-Wheeler Transform.
/// Returns (transformed data, original pointer).
fn bwt_transform(data : Bytes) -> (Bytes, Int) {
  let n = data.length()
  if n == 0 {
    return (b"", 0)
  }
  // Build suffix array using simple doubling algorithm
  let sa = suffix_array(data)
  // BWT: last column = data[(sa[i] + n - 1) % n]
  let bwt = Bytes::makei(n, fn(i) { data[(sa[i] + n - 1) % n] })
  // Find original pointer: position where sa[i] == 0
  let mut orig_ptr = 0
  for i in 0..<n {
    if sa[i] == 0 {
      orig_ptr = i
      break
    }
  }
  (bwt, orig_ptr)
}

///|
/// Simple suffix array construction using doubling.
fn suffix_array(data : Bytes) -> FixedArray[Int] {
  let n = data.length()
  let sa = FixedArray::makei(n, fn(i) { i })
  let rank = FixedArray::makei(n, fn(i) { data[i].to_int() })
  let tmp = FixedArray::make(n, 0)
  let mut k = 1
  while k < n {
    // Sort by (rank[i], rank[i+k])
    // Use radix sort for speed
    let max_rank = {
      let mut m = 0
      for i in 0..<n {
        if rank[i] > m {
          m = rank[i]
        }
      }
      m + 1
    }
    // Sort by second key first
    let count = FixedArray::make(max_rank + 1, 0)
    for i in 0..<n {
      let r2 = if sa[i] + k < n { rank[sa[i] + k] + 1 } else { 0 }
      count[r2] += 1
    }
    let mut sum = 0
    for i in 0..<=max_rank {
      let c = count[i]
      count[i] = sum
      sum += c
    }
    let sa2 = FixedArray::make(n, 0)
    for i in 0..<n {
      let r2 = if sa[i] + k < n { rank[sa[i] + k] + 1 } else { 0 }
      sa2[count[r2]] = sa[i]
      count[r2] += 1
    }
    // Sort by first key (stable)
    let count2 = FixedArray::make(max_rank + 1, 0)
    for i in 0..<n {
      count2[rank[sa2[i]]] += 1
    }
    sum = 0
    for i in 0..<max_rank {
      let c = count2[i]
      count2[i] = sum
      sum += c
    }
    for i in 0..<n {
      let r1 = rank[sa2[i]]
      sa[count2[r1]] = sa2[i]
      count2[r1] += 1
    }
    // Recompute ranks
    tmp[sa[0]] = 0
    for i in 1..<n {
      let prev_r1 = rank[sa[i - 1]]
      let curr_r1 = rank[sa[i]]
      let prev_r2 = if sa[i - 1] + k < n { rank[sa[i - 1] + k] } else { -1 }
      let curr_r2 = if sa[i] + k < n { rank[sa[i] + k] } else { -1 }
      tmp[sa[i]] = tmp[sa[i - 1]] +
        (if curr_r1 != prev_r1 || curr_r2 != prev_r2 { 1 } else { 0 })
    }
    FixedArray::unsafe_blit(rank, 0, tmp, 0, n)
    // Check if all ranks are unique
    if rank[sa[n - 1]] == n - 1 {
      break
    }
    k *= 2
  }
  sa
}

///|
/// MTF encode + RLE2 (RUNA/RUNB zero-run encoding).
/// Returns (encoded symbols, num_in_use, in_use bitmap).
fn mtf_rle2_encode(data : Bytes) -> (Array[Int], Int, FixedArray[Bool]) {
  let n = data.length()
  // Build in_use bitmap
  let in_use = FixedArray::make(256, false)
  for i in 0..<n {
    in_use[data[i].to_int()] = true
  }
  let mut num_in_use = 0
  let mtf_list = FixedArray::make(256, b'\x00')
  for i in 0..<256 {
    if in_use[i] {
      mtf_list[num_in_use] = i.to_byte()
      num_in_use += 1
    }
  }
  // MTF encode
  let symbols : Array[Int] = []
  let mut zero_run = 0
  for i in 0..<n {
    let b = data[i]
    // Find position in MTF list
    let mut pos = 0
    while pos < num_in_use && mtf_list[pos] != b {
      pos += 1
    }
    // Move to front
    let val = mtf_list[pos]
    for j = pos; j > 0; j = j - 1 {
      mtf_list[j] = mtf_list[j - 1]
    }
    mtf_list[0] = val
    if pos == 0 {
      zero_run += 1
    } else {
      // Flush zero run as RUNA/RUNB
      if zero_run > 0 {
        flush_zero_run(symbols, zero_run)
        zero_run = 0
      }
      // Symbol is MTF index + 1 (offset by RUNA/RUNB)
      symbols.push(pos + 1)
    }
  }
  // Flush final zero run
  if zero_run > 0 {
    flush_zero_run(symbols, zero_run)
  }
  // EOB symbol
  symbols.push(num_in_use + 1)
  (symbols, num_in_use, in_use)
}

///|
/// Encode a zero run using RUNA (0) and RUNB (1) symbols.
/// Uses bijective base-2 encoding.
fn flush_zero_run(symbols : Array[Int], run : Int) -> Unit {
  let mut n = run
  while n > 0 {
    if (n & 1) == 1 {
      symbols.push(0) // RUNA
    } else {
      symbols.push(1) // RUNB
    }
    n = (n - 1) >> 1
  }
}

///|
/// Write a single bzip2 compressed block.
fn write_block(
  bw : Bzip2BitWriter,
  symbols : Array[Int],
  num_in_use : Int,
  in_use : FixedArray[Bool],
  orig_ptr : Int,
  block_crc : UInt,
) -> Unit {
  // Block magic: 0x314159265359
  bw.write_bits(0x314159U, 24)
  bw.write_bits(0x265359U, 24)
  // Block CRC
  bw.write_bits(block_crc >> 16, 16)
  bw.write_bits(block_crc & 0xFFFFU, 16)
  // Randomized flag (always false)
  bw.write_bits(0U, 1)
  // Original pointer
  bw.write_bits(orig_ptr.reinterpret_as_uint(), 24)
  // Symbol map: 16 groups of 16
  let mut used_groups = 0U
  for g in 0..<16 {
    let mut any = false
    for j in 0..<16 {
      if in_use[g * 16 + j] {
        any = true
        break
      }
    }
    if any {
      used_groups = used_groups | (1U << (15 - g))
    }
  }
  bw.write_bits(used_groups, 16)
  for g in 0..<16 {
    if (used_groups & (1U << (15 - g))) != 0U {
      let mut group_bits = 0U
      for j in 0..<16 {
        if in_use[g * 16 + j] {
          group_bits = group_bits | (1U << (15 - j))
        }
      }
      bw.write_bits(group_bits, 16)
    }
  }
  // Build Huffman tree for the symbols
  let alpha_size = num_in_use + 2 // RUNA, RUNB, symbols 1..num_in_use-1, EOB
  let freqs = FixedArray::make(alpha_size, 0)
  for s in symbols {
    freqs[s] += 1
  }
  let lengths = bzip2_compute_lengths(freqs, alpha_size, BZIP2_MAX_CODE_LEN)
  // Use a single Huffman tree (num_trees = 2 is minimum, but we duplicate)
  let num_trees = 2
  let num_selectors = (symbols.length() + 49) / 50
  // Number of trees (3 bits)
  bw.write_bits(num_trees.reinterpret_as_uint(), 3)
  // Number of selectors (15 bits)
  bw.write_bits(num_selectors.reinterpret_as_uint(), 15)
  // Selectors: all select tree 0, MTF encoded (tree 0 = 0 zeros)
  for _ in 0..<num_selectors {
    bw.write_bits(0U, 1) // 0 = select first tree (no prefix 1-bits)
  }
  // Write code lengths for both trees (they're identical)
  for _ in 0..<num_trees {
    let mut curr = lengths[0]
    bw.write_bits(curr.reinterpret_as_uint(), 5)
    for j in 0..<alpha_size {
      while curr != lengths[j] {
        bw.write_bits(1U, 1) // need adjustment
        if curr < lengths[j] {
          bw.write_bits(0U, 1) // increment
          curr += 1
        } else {
          bw.write_bits(1U, 1) // decrement
          curr -= 1
        }
      }
      bw.write_bits(0U, 1) // done with this symbol
    }
  }
  // Build canonical codes
  let codes = build_canonical_codes(lengths, alpha_size)
  // Encode symbols
  for s in symbols {
    let code = codes[s]
    let len = lengths[s]
    bw.write_bits(code, len)
  }
}

///|
/// Compute Huffman code lengths for bzip2 (simple approach).
fn bzip2_compute_lengths(
  freqs : FixedArray[Int],
  n : Int,
  max_len : Int,
) -> FixedArray[Int] {
  let lengths = FixedArray::make(n, 0)
  // Count active symbols
  let mut active = 0
  for i in 0..<n {
    if freqs[i] > 0 {
      active += 1
    }
  }
  if active == 0 {
    // All symbols get length 1 (shouldn't happen with EOB)
    for i in 0..<n {
      lengths[i] = 1
    }
    return lengths
  }
  if active == 1 {
    for i in 0..<n {
      if freqs[i] > 0 {
        lengths[i] = 1
      }
    }
    return lengths
  }
  // Build sorted pairs (freq, symbol)
  let sorted = FixedArray::make(active, (0, 0))
  let mut idx = 0
  for i in 0..<n {
    if freqs[i] > 0 {
      sorted[idx] = (freqs[i], i)
      idx += 1
    }
  }
  // Insertion sort by frequency
  for i in 1..<active {
    let key = sorted[i]
    let mut j = i - 1
    while j >= 0 && sorted[j].0 > key.0 {
      sorted[j + 1] = sorted[j]
      j -= 1
    }
    sorted[j + 1] = key
  }
  // Two-queue Huffman tree
  let leaf_freq = FixedArray::makei(active, fn(i) { sorted[i].0 })
  let total_nodes = 2 * active - 1
  let parent = FixedArray::make(total_nodes, -1)
  let node_freq = FixedArray::make(total_nodes, 0)
  for i in 0..<active {
    node_freq[i] = leaf_freq[i]
  }
  let mut leaf_ptr = 0
  let mut int_ptr = active
  let mut next_node = active
  for _ in 0..<(active - 1) {
    let left = if leaf_ptr < active &&
      (int_ptr >= next_node || leaf_freq[leaf_ptr] <= node_freq[int_ptr]) {
      let r = leaf_ptr
      leaf_ptr += 1
      r
    } else {
      let r = int_ptr
      int_ptr += 1
      r
    }
    let right = if leaf_ptr < active &&
      (int_ptr >= next_node || leaf_freq[leaf_ptr] <= node_freq[int_ptr]) {
      let r = leaf_ptr
      leaf_ptr += 1
      r
    } else {
      let r = int_ptr
      int_ptr += 1
      r
    }
    node_freq[next_node] = node_freq[left] + node_freq[right]
    parent[left] = next_node
    parent[right] = next_node
    next_node += 1
  }
  // Compute depths
  let depths = FixedArray::make(total_nodes, 0)
  for i = total_nodes - 1; i >= 0; i = i - 1 {
    if parent[i] >= 0 {
      depths[i] = depths[parent[i]] + 1
    }
  }
  for i in 0..<active {
    lengths[sorted[i].1] = depths[i]
  }
  // Clamp to max_len
  for i in 0..<n {
    if lengths[i] > max_len {
      lengths[i] = max_len
    }
  }
  // Assign length 1 to zero-frequency symbols that still need codes
  for i in 0..<n {
    if freqs[i] == 0 && lengths[i] == 0 {
      lengths[i] = max_len
    }
  }
  lengths
}

///|
/// Build MSB-first canonical Huffman codes from code lengths.
fn build_canonical_codes(
  lengths : FixedArray[Int],
  n : Int,
) -> FixedArray[UInt] {
  let mut max_len = 0
  for i in 0..<n {
    if lengths[i] > max_len {
      max_len = lengths[i]
    }
  }
  // Count codes per length
  let count = FixedArray::make(max_len + 1, 0)
  for i in 0..<n {
    if lengths[i] > 0 {
      count[lengths[i]] += 1
    }
  }
  // Assign codes
  let next_code = FixedArray::make(max_len + 1, 0)
  let mut code = 0
  for bits in 1..<=max_len {
    code = (code + count[bits - 1]) << 1
    next_code[bits] = code
  }
  let codes = FixedArray::make(n, 0U)
  for i in 0..<n {
    let len = lengths[i]
    if len > 0 {
      codes[i] = next_code[len].reinterpret_as_uint()
      next_code[len] += 1
    }
  }
  codes
}

///|
/// CRC-32 over a range of bytes.
fn bzip2_crc32_range(data : Bytes, start : Int, end : Int) -> UInt {
  let mut crc = 0xFFFFFFFF_U
  for i in start..<end {
    let idx = ((crc >> 24) ^ data[i].to_uint()) & 0xFFU
    crc = (crc << 8) ^ bzip2_crc_table[idx.reinterpret_as_int()]
  }
  crc ^ 0xFFFFFFFF_U
}

///|
/// Bit writer for bzip2 (MSB-first).
priv struct Bzip2BitWriter {
  mut buf : FixedArray[Byte]
  mut pos : Int
  mut bits : UInt
  mut n_bits : Int
}

///|
fn Bzip2BitWriter::new(size_hint? : Int = 256) -> Bzip2BitWriter {
  let cap = if size_hint > 256 { size_hint } else { 256 }
  { buf: FixedArray::make(cap, b'\x00'), pos: 0, bits: 0U, n_bits: 0 }
}

///|
fn Bzip2BitWriter::ensure_capacity(self : Bzip2BitWriter, needed : Int) -> Unit {
  if self.pos + needed > self.buf.length() {
    let new_cap = if self.buf.length() * 2 > self.pos + needed {
      self.buf.length() * 2
    } else {
      self.pos + needed
    }
    let new_buf = FixedArray::make(new_cap, b'\x00')
    @blit.blit_bytes(new_buf, 0, self.buf, 0, self.pos)
    self.buf = new_buf
  }
}

///|
fn Bzip2BitWriter::write_bits(
  self : Bzip2BitWriter,
  val : UInt,
  n : Int,
) -> Unit {
  // MSB-first: pack bits from left
  let mut remaining = n
  let mut v = val
  while remaining > 0 {
    let space = 8 - self.n_bits
    if remaining >= space {
      self.bits = (self.bits << space) | (v >> (remaining - space))
      v = v & ((1U << (remaining - space)) - 1U)
      remaining -= space
      if self.pos == self.buf.length() {
        self.ensure_capacity(1)
      }
      self.buf.unsafe_set(self.pos, self.bits.to_byte())
      self.pos += 1
      self.bits = 0U
      self.n_bits = 0
    } else {
      self.bits = (self.bits << remaining) | v
      self.n_bits += remaining
      remaining = 0
    }
  }
}

///|
fn Bzip2BitWriter::write_byte(self : Bzip2BitWriter, b : Byte) -> Unit {
  self.write_bits(b.to_uint(), 8)
}

///|
fn Bzip2BitWriter::flush(self : Bzip2BitWriter) -> Unit {
  if self.n_bits > 0 {
    self.bits = self.bits << (8 - self.n_bits)
    if self.pos == self.buf.length() {
      self.ensure_capacity(1)
    }
    self.buf.unsafe_set(self.pos, self.bits.to_byte())
    self.pos += 1
    self.bits = 0U
    self.n_bits = 0
  }
}

///|
fn Bzip2BitWriter::to_bytes(self : Bzip2BitWriter) -> Bytes {
  if self.pos == self.buf.length() {
    return self.buf.unsafe_reinterpret_as_bytes()
  }
  let result = @blit.make_uninit(self.pos)
  @blit.blit_bytes(result, 0, self.buf, 0, self.pos)
  result.unsafe_reinterpret_as_bytes()
}
