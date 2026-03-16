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
    let block_crc = compress_block(bw, data, offset, end)
    stream_crc = ((stream_crc << 1) | (stream_crc >> 31)) ^ block_crc
    offset = end
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
/// Compresses a single block of data. Returns the block CRC.
fn compress_block(
  bw : Bzip2BitWriter,
  data : Bytes,
  start : Int,
  end : Int,
) -> UInt {
  let rle1 = rle1_encode(data, start, end)
  let (bwt_data, orig_ptr) = bwt_transform(rle1)
  let (symbols, num_in_use, in_use) = mtf_rle2_encode(bwt_data)
  let block_crc = bzip2_crc32_range(data, start, end)
  write_block(bw, symbols, num_in_use, in_use, orig_ptr, block_crc)
  block_crc
}

///|
/// RLE1 encode: runs of 4+ identical bytes → 4 copies + count byte.
/// Uses a pre-allocated FixedArray to avoid Buffer::write_byte overhead.
fn rle1_encode(data : Bytes, start : Int, end : Int) -> Bytes {
  let len = end - start
  // Worst case: no runs, output = input length. With runs, output ≤ input.
  // RLE can expand slightly: 4 bytes → 5 bytes (4 copies + count=0).
  // Worst expansion: every 4 bytes becomes 5, so max = len * 5 / 4 + 1.
  let max_out = len + (len / 4) + 2
  let out = FixedArray::make(max_out, b'\x00')
  let mut pos = 0
  let mut i = start
  while i < end {
    let b = data[i]
    let mut run = 1
    while i + run < end && data[i + run] == b && run < 259 {
      run += 1
    }
    if run >= 4 {
      out.unsafe_set(pos, b)
      out.unsafe_set(pos + 1, b)
      out.unsafe_set(pos + 2, b)
      out.unsafe_set(pos + 3, b)
      out.unsafe_set(pos + 4, (run - 4).to_byte())
      pos += 5
      i += run
    } else {
      out.unsafe_set(pos, b)
      pos += 1
      i += 1
    }
  }
  let result = @blit.make_uninit(pos)
  @blit.blit_fixed_array(result, 0, out, 0, pos)
  result.unsafe_reinterpret_as_bytes()
}

///|
/// Burrows-Wheeler Transform using suffix array construction.
/// Returns (transformed data, original pointer).
fn bwt_transform(data : Bytes) -> (Bytes, Int) {
  let n = data.length()
  if n == 0 {
    return (b"", 0)
  }
  let sa = build_suffix_array(data)
  // SA has exactly n entries — circular rotation ordering.
  let bwt = @blit.make_uninit(n)
  let mut orig_ptr = 0
  for i in 0..<n {
    let s = sa.unsafe_get(i)
    if s == 0 {
      orig_ptr = i
      bwt.unsafe_set(i, data[n - 1])
    } else {
      bwt.unsafe_set(i, data[s - 1])
    }
  }
  (bwt.unsafe_reinterpret_as_bytes(), orig_ptr)
}


///|
/// MTF encode + RLE2 (RUNA/RUNB zero-run encoding).
/// Returns (encoded symbols, num_in_use, in_use bitmap).
fn mtf_rle2_encode(data : Bytes) -> (Array[Int], Int, FixedArray[Bool]) {
  // Build in_use bitmap
  let in_use = FixedArray::make(256, false)
  for _, b in data {
    in_use[b.to_int()] = true
  }
  let mtf_list = FixedArray::make(256, b'\x00')
  let num_in_use = for i = 0, num_in_use = 0; i < 256; i = i + 1 {
    if in_use[i] {
      mtf_list[num_in_use] = i.to_byte()
      continue i + 1, num_in_use + 1
    } else {
      continue i + 1, num_in_use
    }
  } nobreak {
    num_in_use
  }
  // MTF encode
  let symbols : Array[Int] = []
  let mut zero_run = 0
  for b in data {
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
/// All symbols must get a valid code length, so zero-frequency symbols
/// are given frequency 1 to include them in the Huffman tree.
fn bzip2_compute_lengths(
  freqs : FixedArray[Int],
  n : Int,
  max_len : Int,
) -> FixedArray[Int] {
  let lengths = FixedArray::make(n, 0)
  if n < 2 {
    for i in 0..<n {
      lengths[i] = 1
    }
    return lengths
  }
  // Ensure all symbols have frequency >= 1 so the Huffman tree
  // covers the full alphabet without overflowing the code space.
  let adj_freqs = FixedArray::makei(n, fn(i) {
    if freqs[i] > 0 {
      freqs[i]
    } else {
      1
    }
  })
  // Build sorted pairs (freq, symbol)
  let sorted = FixedArray::makei(n, fn(i) { (adj_freqs[i], i) })
  // Insertion sort by frequency
  for i in 1..<n {
    let key = sorted[i]
    let mut j = i - 1
    while j >= 0 && sorted[j].0 > key.0 {
      sorted[j + 1] = sorted[j]
      j -= 1
    }
    sorted[j + 1] = key
  }
  // Two-queue Huffman tree
  let leaf_freq = FixedArray::makei(n, fn(i) { sorted[i].0 })
  let total_nodes = 2 * n - 1
  let parent = FixedArray::make(total_nodes, -1)
  let node_freq = FixedArray::make(total_nodes, 0)
  for i in 0..<n {
    node_freq[i] = leaf_freq[i]
  }
  let mut leaf_ptr = 0
  let mut int_ptr = n
  let mut next_node = n
  for _ in 0..<(n - 1) {
    let left = if leaf_ptr < n &&
      (int_ptr >= next_node || leaf_freq[leaf_ptr] <= node_freq[int_ptr]) {
      let r = leaf_ptr
      leaf_ptr += 1
      r
    } else {
      let r = int_ptr
      int_ptr += 1
      r
    }
    let right = if leaf_ptr < n &&
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
  for i in 0..<n {
    lengths[sorted[i].1] = depths[i]
  }
  // Clamp to max_len
  for i in 0..<n {
    if lengths[i] > max_len {
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
  let max_len = for i = 0, max_len = 0; i < n; i = i + 1 {
    continue i + 1, if lengths[i] > max_len { lengths[i] } else { max_len }
  } nobreak {
    max_len
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
    @blit.blit_fixed_array(new_buf, 0, self.buf, 0, self.pos)
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
/// Extract accumulated complete bytes without flushing partial bits.
fn Bzip2BitWriter::take_output(self : Bzip2BitWriter) -> Bytes {
  if self.pos == 0 {
    return Bytes::default()
  }
  let result = @blit.make_uninit(self.pos)
  @blit.blit_fixed_array(result, 0, self.buf, 0, self.pos)
  self.pos = 0
  result.unsafe_reinterpret_as_bytes()
}

///|
fn Bzip2BitWriter::to_bytes(self : Bzip2BitWriter) -> Bytes {
  if self.pos == self.buf.length() {
    return self.buf.unsafe_reinterpret_as_bytes()
  }
  let result = @blit.make_uninit(self.pos)
  @blit.blit_fixed_array(result, 0, self.buf, 0, self.pos)
  result.unsafe_reinterpret_as_bytes()
}
