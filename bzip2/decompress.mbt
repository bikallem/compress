///|
/// Decompresses bzip2-encoded data.
pub fn decompress(data : Bytes) -> Bytes raise Bzip2Error {
  let br = Bzip2BitReader::new(data)
  let out = @buffer.new(size_hint=data.length() * 4)
  // Read stream header: 'B' 'Z' 'h' blockSize
  let m1 = br.read_bits(8)
  let m2 = br.read_bits(8)
  if m1 != BZIP2_MAGIC1.to_uint() || m2 != BZIP2_MAGIC2.to_uint() {
    raise Bzip2Error::InvalidHeader("invalid bzip2 magic")
  }
  let version = br.read_bits(8)
  if version != b'h'.to_uint() {
    raise Bzip2Error::InvalidHeader("unsupported bzip2 version")
  }
  let block_size_char = br.read_bits(8)
  if block_size_char < b'1'.to_uint() || block_size_char > b'9'.to_uint() {
    raise Bzip2Error::InvalidHeader("invalid block size")
  }
  let block_size_100k = (block_size_char - b'0'.to_uint()).reinterpret_as_int()
  let max_block_bytes = block_size_100k * 100000
  let mut stream_crc = 0U
  // Process blocks
  while true {
    // Read 48-bit magic
    let magic_hi = br.read_bits(24)
    let magic_lo = br.read_bits(24)
    // Check for end of stream: 0x177245385090
    if magic_hi == 0x177245U && magic_lo == 0x385090U {
      let stored_crc = (br.read_bits(16) << 16) | br.read_bits(16)
      if stored_crc != stream_crc {
        raise Bzip2Error::ChecksumMismatch(expected=stored_crc, got=stream_crc)
      }
      break
    }
    // Check for block magic: 0x314159265359
    if magic_hi != 0x314159U || magic_lo != 0x265359U {
      raise Bzip2Error::CorruptData("invalid block magic")
    }
    let block_crc = (br.read_bits(16) << 16) | br.read_bits(16)
    let randomized = br.read_bit()
    if randomized {
      raise Bzip2Error::CorruptData("randomized blocks not supported")
    }
    let orig_ptr = br.read_bits(24).reinterpret_as_int()
    let block_data = decode_block(br, max_block_bytes, orig_ptr)
    // Verify block CRC
    let actual_crc = bzip2_crc32(block_data)
    if actual_crc != block_crc {
      raise Bzip2Error::ChecksumMismatch(expected=block_crc, got=actual_crc)
    }
    // Update stream CRC
    stream_crc = ((stream_crc << 1) | (stream_crc >> 31)) ^ actual_crc
    for i in 0..<block_data.length() {
      out.write_byte(block_data[i])
    }
  }
  out.to_bytes()
}

///|
fn decode_block(
  br : Bzip2BitReader,
  max_block_bytes : Int,
  orig_ptr : Int,
) -> Bytes raise Bzip2Error {
  // Read symbol map
  let used_groups = br.read_bits(16)
  let in_use = FixedArray::make(256, false)
  let mut num_in_use = 0
  for i in 0..<16 {
    if (used_groups & (1U << (15 - i))) != 0U {
      let group_bitmap = br.read_bits(16)
      for j in 0..<16 {
        if (group_bitmap & (1U << (15 - j))) != 0U {
          in_use[i * 16 + j] = true
          num_in_use += 1
        }
      }
    }
  }
  if num_in_use == 0 {
    raise Bzip2Error::CorruptData("no symbols in use")
  }
  let alpha_size = num_in_use + 2 // RUNA, RUNB, symbols..., EOB
  // Read Huffman tables
  let num_trees = br.read_bits(3).reinterpret_as_int()
  if num_trees < 2 || num_trees > 6 {
    raise Bzip2Error::CorruptData("invalid number of Huffman trees")
  }
  let num_selectors = br.read_bits(15).reinterpret_as_int()
  if num_selectors < 1 {
    raise Bzip2Error::CorruptData("invalid number of selectors")
  }
  // Read selectors (MTF encoded)
  let selectors = FixedArray::make(num_selectors, 0)
  for i in 0..<num_selectors {
    let mut j = 0
    while br.read_bit() {
      j += 1
      if j >= num_trees {
        raise Bzip2Error::CorruptData("invalid selector")
      }
    }
    selectors[i] = j
  }
  // Undo MTF on selectors
  let sel_mtf = FixedArray::make(num_trees, 0)
  for i in 0..<num_trees {
    sel_mtf[i] = i
  }
  for i in 0..<num_selectors {
    let idx = selectors[i]
    let val = sel_mtf[idx]
    for j = idx; j > 0; j = j - 1 {
      sel_mtf[j] = sel_mtf[j - 1]
    }
    sel_mtf[0] = val
    selectors[i] = val
  }
  // Read Huffman code lengths for each tree
  let trees : Array[Bzip2HuffmanDecoder] = []
  for _ in 0..<num_trees {
    let lengths = FixedArray::make(alpha_size, 0)
    let mut curr = br.read_bits(5).reinterpret_as_int()
    for j in 0..<alpha_size {
      while true {
        if not(br.read_bit()) {
          break
        }
        if br.read_bit() {
          curr -= 1
        } else {
          curr += 1
        }
      }
      if curr < 1 || curr > BZIP2_MAX_CODE_LEN {
        raise Bzip2Error::CorruptData("invalid code length")
      }
      lengths[j] = curr
    }
    trees.push(Bzip2HuffmanDecoder::build(lengths, alpha_size))
  }
  // Decode MTF-encoded symbols
  // Symbols: 0=RUNA, 1=RUNB, 2..num_in_use = MTF indices 1..num_in_use-1, num_in_use+1 = EOB
  let tt = FixedArray::make(max_block_bytes, 0) // Will hold byte values after MTF decode
  let mut decoded_len = 0
  let mut group_pos = 0
  let mut group_no = -1
  let mut current_tree = trees[0]
  let eob = num_in_use + 1
  // MTF list for byte values
  let mtf_list = FixedArray::make(num_in_use, b'\x00')
  let mut k = 0
  for i in 0..<256 {
    if in_use[i] {
      mtf_list[k] = i.to_byte()
      k += 1
    }
  }
  while true {
    if group_pos == 0 {
      group_no += 1
      if group_no >= num_selectors {
        raise Bzip2Error::CorruptData("ran out of selectors")
      }
      current_tree = trees[selectors[group_no]]
      group_pos = 50
    }
    group_pos -= 1
    let sym = current_tree.decode(br)
    if sym == eob {
      break
    }
    if sym == 0 || sym == 1 {
      // RUNA/RUNB run-length encoding for mtf_list[0]
      let repeat_byte = mtf_list[0]
      let mut run_len = 0
      let mut run_power = 1
      let mut s = sym
      while s == 0 || s == 1 {
        run_len += (s + 1) * run_power
        run_power *= 2
        // Get next symbol
        if group_pos == 0 {
          group_no += 1
          if group_no >= num_selectors {
            raise Bzip2Error::CorruptData("ran out of selectors")
          }
          current_tree = trees[selectors[group_no]]
          group_pos = 50
        }
        group_pos -= 1
        s = current_tree.decode(br)
      }
      // Emit run_len copies of repeat_byte
      for _ in 0..<run_len {
        if decoded_len >= max_block_bytes {
          raise Bzip2Error::CorruptData("block too large")
        }
        tt[decoded_len] = repeat_byte.to_int()
        decoded_len += 1
      }
      // Process the non-RUNA/RUNB symbol we just read
      if s == eob {
        break
      }
      // Regular symbol: s >= 2, MTF index = s - 1
      let mtf_idx = s - 1
      if mtf_idx >= num_in_use {
        raise Bzip2Error::CorruptData("MTF index out of range")
      }
      let byte_val = mtf_list[mtf_idx]
      // Move to front
      for j = mtf_idx; j > 0; j = j - 1 {
        mtf_list[j] = mtf_list[j - 1]
      }
      mtf_list[0] = byte_val
      if decoded_len >= max_block_bytes {
        raise Bzip2Error::CorruptData("block too large")
      }
      tt[decoded_len] = byte_val.to_int()
      decoded_len += 1
    } else {
      // Regular symbol: sym >= 2, MTF index = sym - 1
      let mtf_idx = sym - 1
      if mtf_idx >= num_in_use {
        raise Bzip2Error::CorruptData("MTF index out of range")
      }
      let byte_val = mtf_list[mtf_idx]
      // Move to front
      for j = mtf_idx; j > 0; j = j - 1 {
        mtf_list[j] = mtf_list[j - 1]
      }
      mtf_list[0] = byte_val
      if decoded_len >= max_block_bytes {
        raise Bzip2Error::CorruptData("block too large")
      }
      tt[decoded_len] = byte_val.to_int()
      decoded_len += 1
    }
  }
  // Inverse BWT using LF mapping
  if orig_ptr < 0 || orig_ptr >= decoded_len {
    raise Bzip2Error::CorruptData("invalid original pointer")
  }
  let bwt_output = inverse_bwt(tt, decoded_len, orig_ptr)
  // Undo RLE1: consecutive runs of 4+ identical bytes are encoded as
  // 4 copies of byte followed by a repeat count byte
  undo_rle1(bwt_output)
}

///|
/// Performs inverse Burrows-Wheeler Transform using LF mapping.
fn inverse_bwt(data : FixedArray[Int], length : Int, orig_ptr : Int) -> Bytes {
  // Count occurrences of each byte value
  let counts = FixedArray::make(256, 0)
  for i in 0..<length {
    counts[data[i]] += 1
  }
  // Compute cumulative counts (starting positions in F column)
  let cum = FixedArray::make(257, 0)
  let mut total = 0
  for i in 0..<256 {
    cum[i] = total
    total += counts[i]
  }
  cum[256] = total
  // Build LF mapping: for each position i in L, LF[i] = corresponding position in F
  let lf = FixedArray::make(length, 0)
  let occ = FixedArray::make(256, 0)
  for i in 0..<length {
    let c = data[i]
    lf[i] = cum[c] + occ[c]
    occ[c] += 1
  }
  // Reconstruct original string by following LF chain.
  // In bzip2, orig_ptr is the row in the sorted rotation matrix where the
  // original string appears. We output characters by following LF mapping:
  // the i-th character of the original is L[LF^i(orig_ptr)].
  // But since LF maps L position → F position, and F[i] = L[LF^{-1}(i)],
  // we need to follow the chain carefully.
  //
  // Standard approach: output[i] = L[pos], pos = LF[pos]
  // But we need to find the right starting position.
  // orig_ptr is the index in the sorted rotations where the original starts.
  // The first character of the original = F[orig_ptr].
  // F[orig_ptr] = data[T[orig_ptr]] where T is the inverse of LF.
  //
  // Simpler: use the T vector (inverse BWT transform vector).
  // T[i] = LF^{-1}(i): the position in L that maps to sorted position i.
  let t_vec = FixedArray::make(length, 0)
  let pos2 = FixedArray::make(256, 0)
  for i in 0..<256 {
    pos2[i] = cum[i]
  }
  for i in 0..<length {
    let c = data[i]
    t_vec[pos2[c]] = i
    pos2[c] += 1
  }
  // Now t_vec[sorted_pos] = L_pos: F[sorted_pos] corresponds to L[t_vec[sorted_pos]]
  // Follow chain: start at orig_ptr, output L[t_vec[pos]], then pos = lf[t_vec[pos]]...
  // Actually, simpler: just compute the output array directly.
  // decoded[0] = F[orig_ptr], decoded[1] = F[lf[t_vec[orig_ptr]]], ...
  // No, let me use the well-known algorithm from the bzip2 source:
  //
  // Merge data and LF into a single array: tt[i] = (lf[i] << 8) | data[i]
  // Then follow: pos = orig_ptr; for each output char: c = tt[pos] & 0xFF; pos = tt[pos] >> 8
  let tt_merged = FixedArray::make(length, 0)
  for i in 0..<length {
    tt_merged[i] = (lf[i] << 8) | data[i]
  }
  // Output in reverse order since LF goes backwards
  let output = FixedArray::make(length, b'\x00')
  let mut pos = orig_ptr
  for i = length - 1; i >= 0; i = i - 1 {
    let entry = tt_merged[pos]
    output[i] = (entry & 0xFF).to_byte()
    pos = entry >> 8
  }
  let result = @buffer.new(size_hint=length)
  for i in 0..<length {
    result.write_byte(output[i])
  }
  result.to_bytes()
}

///|
/// Undoes bzip2 RLE1 encoding.
/// In RLE1, a run of 4+ identical bytes is stored as:
/// 4 copies of byte + count (where count = number of additional copies beyond 4)
fn undo_rle1(data : Bytes) -> Bytes raise Bzip2Error {
  let out = @buffer.new(size_hint=data.length())
  let mut i = 0
  while i < data.length() {
    let b = data[i]
    out.write_byte(b)
    i += 1
    // Check for run of 4 identical bytes
    if i < data.length() && data[i] == b {
      out.write_byte(b)
      i += 1
      if i < data.length() && data[i] == b {
        out.write_byte(b)
        i += 1
        if i < data.length() && data[i] == b {
          out.write_byte(b)
          i += 1
          // Next byte is repeat count
          if i >= data.length() {
            raise Bzip2Error::CorruptData("unexpected end of RLE1 data")
          }
          let count = data[i].to_int()
          i += 1
          for _ in 0..<count {
            out.write_byte(b)
          }
        }
      }
    }
  }
  out.to_bytes()
}

///|
/// bzip2 CRC-32 (non-reflected polynomial 0x04C11DB7).
let bzip2_crc_table : FixedArray[UInt] = {
  let t = FixedArray::make(256, 0U)
  for i in 0..<256 {
    let mut crc = i.reinterpret_as_uint() << 24
    for _ in 0..<8 {
      if (crc & 0x80000000U) != 0U {
        crc = (crc << 1) ^ 0x04C11DB7U
      } else {
        crc = crc << 1
      }
    }
    t[i] = crc
  }
  t
}

///|
fn bzip2_crc32(data : Bytes) -> UInt {
  let mut crc = 0xFFFFFFFF_U
  for i in 0..<data.length() {
    let idx = ((crc >> 24) ^ data[i].to_uint()) & 0xFFU
    crc = (crc << 8) ^ bzip2_crc_table[idx.reinterpret_as_int()]
  }
  crc ^ 0xFFFFFFFF_U
}
