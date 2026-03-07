///|
/// AsyncBzip2BitReader reads bits MSB-first from an `@io.Reader`.
priv struct AsyncBzip2BitReader {
  source : &@io.Reader
  mut bit_buf : UInt
  mut bits_left : Int
  read_buf : FixedArray[Byte]
}

///|
fn AsyncBzip2BitReader::new(source : &@io.Reader) -> AsyncBzip2BitReader {
  { source, bit_buf: 0U, bits_left: 0, read_buf: FixedArray::make(1, b'\x00') }
}

///|
async fn AsyncBzip2BitReader::read_bits(
  self : AsyncBzip2BitReader,
  n : Int,
) -> UInt {
  while self.bits_left < n {
    let bytes_read = self.source.read(self.read_buf, offset=0, max_len=1)
    if bytes_read == 0 {
      raise Bzip2Error::UnexpectedEOF
    }
    self.bit_buf = (self.bit_buf << 8) | self.read_buf[0].to_uint()
    self.bits_left += 8
  }
  self.bits_left -= n
  (self.bit_buf >> self.bits_left) & ((1U << n) - 1U)
}

///|
async fn AsyncBzip2BitReader::read_bit(self : AsyncBzip2BitReader) -> Bool {
  self.read_bits(1) != 0U
}

///|
async fn Bzip2HuffmanDecoder::async_decode(
  self : Bzip2HuffmanDecoder,
  br : AsyncBzip2BitReader,
) -> Int {
  let mut code = 0
  for i in 1..<=self.max_len {
    let bit = br.read_bits(1).reinterpret_as_int()
    code = (code << 1) | bit
    if i >= self.min_len && code <= self.limits[i] {
      return self.perms[self.bases[i] + code]
    }
  } nobreak {
    raise Bzip2Error::CorruptData("invalid bzip2 Huffman code")
  }
}

///|
/// Streaming decompression of bzip2 data from a reader to a writer.
pub async fn decompress_to(source : &@io.Reader, dest : &@io.Writer) -> Unit {
  let br = AsyncBzip2BitReader::new(source)
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
  while true {
    let magic_hi = br.read_bits(24)
    let magic_lo = br.read_bits(24)
    if magic_hi == 0x177245U && magic_lo == 0x385090U {
      let stored_crc = (br.read_bits(16) << 16) | br.read_bits(16)
      if stored_crc != stream_crc {
        raise Bzip2Error::ChecksumMismatch(expected=stored_crc, got=stream_crc)
      }
      break
    }
    if magic_hi != 0x314159U || magic_lo != 0x265359U {
      raise Bzip2Error::CorruptData("invalid block magic")
    }
    let block_crc = (br.read_bits(16) << 16) | br.read_bits(16)
    let randomized = br.read_bit()
    if randomized {
      raise Bzip2Error::CorruptData("randomized blocks not supported")
    }
    let orig_ptr = br.read_bits(24).reinterpret_as_int()
    let block_data = async_decode_block(br, max_block_bytes, orig_ptr)
    let actual_crc = bzip2_crc32(block_data)
    if actual_crc != block_crc {
      raise Bzip2Error::ChecksumMismatch(expected=block_crc, got=actual_crc)
    }
    stream_crc = ((stream_crc << 1) | (stream_crc >> 31)) ^ actual_crc
    // Write block data to dest
    let mut offset = 0
    let len = block_data.length()
    while offset < len {
      let written = dest.write_once(block_data, offset~, len=len - offset)
      offset += written
    }
  }
}

///|
async fn async_decode_block(
  br : AsyncBzip2BitReader,
  max_block_bytes : Int,
  orig_ptr : Int,
) -> Bytes {
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
  let alpha_size = num_in_use + 2
  let num_trees = br.read_bits(3).reinterpret_as_int()
  if num_trees < 2 || num_trees > 6 {
    raise Bzip2Error::CorruptData("invalid number of Huffman trees")
  }
  let num_selectors = br.read_bits(15).reinterpret_as_int()
  if num_selectors < 1 {
    raise Bzip2Error::CorruptData("invalid number of selectors")
  }
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
  let tt = FixedArray::make(max_block_bytes, 0)
  let mut decoded_len = 0
  let mut group_pos = 0
  let mut group_no = -1
  let mut current_tree = trees[0]
  let eob = num_in_use + 1
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
    let sym = current_tree.async_decode(br)
    if sym == eob {
      break
    }
    if sym == 0 || sym == 1 {
      let repeat_byte = mtf_list[0]
      let mut run_len = 0
      let mut run_power = 1
      let mut s = sym
      while s == 0 || s == 1 {
        run_len += (s + 1) * run_power
        run_power *= 2
        if group_pos == 0 {
          group_no += 1
          if group_no >= num_selectors {
            raise Bzip2Error::CorruptData("ran out of selectors")
          }
          current_tree = trees[selectors[group_no]]
          group_pos = 50
        }
        group_pos -= 1
        s = current_tree.async_decode(br)
      }
      for _ in 0..<run_len {
        if decoded_len >= max_block_bytes {
          raise Bzip2Error::CorruptData("block too large")
        }
        tt[decoded_len] = repeat_byte.to_int()
        decoded_len += 1
      }
      if s == eob {
        break
      }
      let mtf_idx = s - 1
      if mtf_idx >= num_in_use {
        raise Bzip2Error::CorruptData("MTF index out of range")
      }
      let byte_val = mtf_list[mtf_idx]
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
      let mtf_idx = sym - 1
      if mtf_idx >= num_in_use {
        raise Bzip2Error::CorruptData("MTF index out of range")
      }
      let byte_val = mtf_list[mtf_idx]
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
  if orig_ptr < 0 || orig_ptr >= decoded_len {
    raise Bzip2Error::CorruptData("invalid original pointer")
  }
  let bwt_output = inverse_bwt(tt, decoded_len, orig_ptr)
  undo_rle1(bwt_output)
}
