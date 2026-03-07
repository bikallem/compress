///|
/// Decompresses DEFLATE-encoded data (RFC 1951).
pub fn decompress(data : Bytes) -> Bytes raise CompressError {
  decompress_with_dict(data, Bytes::default())
}

///|
/// Decompresses DEFLATE-encoded data with a preset dictionary.
pub fn decompress_with_dict(
  data : Bytes,
  dict : Bytes,
) -> Bytes raise CompressError {
  let out = @buffer.new(size_hint=data.length() * 2)
  let dd = DictDecoder::new()
  if dict.length() > 0 {
    dd.init_dict(dict)
  }
  let bit_buf : Ref[UInt64] = Ref::new(0UL)
  let bit_count : Ref[Int] = Ref::new(0)
  let pos : Ref[Int] = Ref::new(0)
  let mut final_block = false
  while not(final_block) {
    // Read block header
    ensure_bits(bit_buf, bit_count, data, pos, 3)
    let bfinal = (bit_buf.val & 1UL).to_int()
    bit_buf.val = bit_buf.val >> 1
    bit_count.val -= 1
    final_block = bfinal != 0
    let btype = (bit_buf.val & 3UL).to_int()
    bit_buf.val = bit_buf.val >> 2
    bit_count.val -= 2
    match btype {
      0 => decode_stored_block(dd, out, bit_buf, bit_count, data, pos)
      1 =>
        decode_huffman_block(
          dd, out, bit_buf, bit_count, data, pos, fixed_lit_decoder, fixed_dist_decoder,
        )
      2 => {
        let (lit_dec, dist_dec) = read_dynamic_header(
          bit_buf, bit_count, data, pos,
        )
        decode_huffman_block(
          dd, out, bit_buf, bit_count, data, pos, lit_dec, dist_dec,
        )
      }
      _ => raise CompressError::CorruptInput("invalid block type \{btype}")
    }
  }
  // Flush remaining
  dd.read_flush(out)
  out.to_bytes()
}

///|
/// Fill the bit buffer with as many bytes as possible (up to 56 bits).
/// This reduces per-byte overhead by batching reads.
fn fill_bits(
  bit_buf : Ref[UInt64],
  bit_count : Ref[Int],
  data : Bytes,
  pos : Ref[Int],
) -> Unit {
  let data_len = data.length()
  while bit_count.val <= 56 && pos.val < data_len {
    bit_buf.val = bit_buf.val | (data[pos.val].to_uint64() << bit_count.val)
    bit_count.val += 8
    pos.val += 1
  }
}

///|
fn ensure_bits(
  bit_buf : Ref[UInt64],
  bit_count : Ref[Int],
  data : Bytes,
  pos : Ref[Int],
  n : Int,
) -> Unit raise CompressError {
  while bit_count.val < n {
    if pos.val >= data.length() {
      raise CompressError::UnexpectedEOF
    }
    bit_buf.val = bit_buf.val | (data[pos.val].to_uint64() << bit_count.val)
    bit_count.val += 8
    pos.val += 1
  }
}

///|
fn read_bits(
  bit_buf : Ref[UInt64],
  bit_count : Ref[Int],
  data : Bytes,
  pos : Ref[Int],
  n : Int,
) -> Int raise CompressError {
  ensure_bits(bit_buf, bit_count, data, pos, n)
  let mask = (1UL << n) - 1UL
  let val = (bit_buf.val & mask).to_int()
  bit_buf.val = bit_buf.val >> n
  bit_count.val -= n
  val
}

///|
fn decode_stored_block(
  dd : DictDecoder,
  out : @buffer.Buffer,
  bit_buf : Ref[UInt64],
  bit_count : Ref[Int],
  data : Bytes,
  pos : Ref[Int],
) -> Unit raise CompressError {
  // Discard bits up to byte boundary
  let discard = bit_count.val % 8
  if discard > 0 {
    bit_buf.val = bit_buf.val >> discard
    bit_count.val -= discard
  }
  // Read LEN and NLEN
  let len = read_bits(bit_buf, bit_count, data, pos, 16)
  let nlen = read_bits(bit_buf, bit_count, data, pos, 16)
  if (len ^ nlen) != 0xFFFF {
    raise CompressError::CorruptInput("invalid stored block lengths")
  }
  // Copy raw bytes
  for _ in 0..<len {
    let b = read_bits(bit_buf, bit_count, data, pos, 8).to_byte()
    dd.write_byte(b)
    if dd.avail_write() == 0 {
      dd.read_flush(out)
    }
  }
}

///|
fn decode_huffman_block(
  dd : DictDecoder,
  out : @buffer.Buffer,
  bit_buf : Ref[UInt64],
  bit_count : Ref[Int],
  data : Bytes,
  pos : Ref[Int],
  lit_dec : HuffmanDecoder,
  dist_dec : HuffmanDecoder,
) -> Unit raise CompressError {
  let chunk_mask = (1UL << HUFFMAN_CHUNK_BITS) - 1UL
  let lit_chunks = lit_dec.chunks
  while true {
    // Eagerly fill the bit buffer to reduce per-symbol overhead
    fill_bits(bit_buf, bit_count, data, pos)
    // Fast path: inline the common case of direct chunk lookup
    let idx = (bit_buf.val & chunk_mask).to_int()
    let entry = lit_chunks[idx]
    let sym = if (entry & 0x80U) == 0U &&
      bit_count.val >= (entry & 0xFFU).reinterpret_as_int() {
      let n = (entry & 0xFFU).reinterpret_as_int()
      let s = (entry >> 8).reinterpret_as_int()
      bit_buf.val = bit_buf.val >> n
      bit_count.val -= n
      s
    } else {
      // Slow path: link table lookup or insufficient bits
      lit_dec.decode(bit_buf, bit_count, data, pos)
    }
    if sym < 256 {
      // Literal byte
      dd.write_byte(sym.to_byte())
      if dd.avail_write() == 0 {
        dd.read_flush(out)
      }
    } else if sym == END_BLOCK_MARKER {
      dd.read_flush(out)
      return
    } else {
      // Length-distance pair
      let length_code = sym - 257
      if length_code >= length_base.length() {
        raise CompressError::CorruptInput("invalid length code \{sym}")
      }
      let extra = length_extra[length_code]
      let extra_val = if extra > 0 {
        ensure_bits(bit_buf, bit_count, data, pos, extra)
        let mask = (1UL << extra) - 1UL
        let val = (bit_buf.val & mask).to_int()
        bit_buf.val = bit_buf.val >> extra
        bit_count.val -= extra
        val
      } else {
        0
      }
      let length = length_base[length_code] + extra_val
      // Decode distance - inline fast path
      fill_bits(bit_buf, bit_count, data, pos)
      let dist_chunks = dist_dec.chunks
      let dist_idx = (bit_buf.val & chunk_mask).to_int()
      let dist_entry = dist_chunks[dist_idx]
      let dist_sym = if (dist_entry & 0x80U) == 0U &&
        bit_count.val >= (dist_entry & 0xFFU).reinterpret_as_int() {
        let n = (dist_entry & 0xFFU).reinterpret_as_int()
        let s = (dist_entry >> 8).reinterpret_as_int()
        bit_buf.val = bit_buf.val >> n
        bit_count.val -= n
        s
      } else {
        dist_dec.decode(bit_buf, bit_count, data, pos)
      }
      if dist_sym >= dist_base.length() {
        raise CompressError::CorruptInput("invalid distance code \{dist_sym}")
      }
      let dextra = dist_extra[dist_sym]
      let dextra_val = if dextra > 0 {
        ensure_bits(bit_buf, bit_count, data, pos, dextra)
        let mask = (1UL << dextra) - 1UL
        let val = (bit_buf.val & mask).to_int()
        bit_buf.val = bit_buf.val >> dextra
        bit_count.val -= dextra
        val
      } else {
        0
      }
      let dist = dist_base[dist_sym] + dextra_val
      if dist > dd.hist_size() {
        raise CompressError::CorruptInput(
          "distance \{dist} exceeds history \{dd.hist_size()}",
        )
      }
      // Copy match
      let mut remaining = length
      while remaining > 0 {
        let n = dd.write_copy(dist, remaining)
        remaining -= n
        if dd.avail_write() == 0 {
          dd.read_flush(out)
        }
      }
    }
  }
}

///|
fn read_dynamic_header(
  bit_buf : Ref[UInt64],
  bit_count : Ref[Int],
  data : Bytes,
  pos : Ref[Int],
) -> (HuffmanDecoder, HuffmanDecoder) raise CompressError {
  let hlit = read_bits(bit_buf, bit_count, data, pos, 5) + 257
  let hdist = read_bits(bit_buf, bit_count, data, pos, 5) + 1
  let hclen = read_bits(bit_buf, bit_count, data, pos, 4) + 4
  // Read code length code lengths
  let cl_lengths = FixedArray::make(NUM_CODES, 0)
  for i in 0..<hclen {
    cl_lengths[code_order[i]] = read_bits(bit_buf, bit_count, data, pos, 3)
  }
  let cl_decoder = HuffmanDecoder::build(cl_lengths)
  // Read literal/length and distance code lengths
  let total = hlit + hdist
  let lengths = FixedArray::make(total, 0)
  let mut i = 0
  while i < total {
    let sym = cl_decoder.decode(bit_buf, bit_count, data, pos)
    if sym < 16 {
      lengths[i] = sym
      i += 1
    } else if sym == 16 {
      // Repeat previous
      guard i > 0 else {
        raise CompressError::CorruptInput("repeat with no previous length")
      }
      let repeat_count = read_bits(bit_buf, bit_count, data, pos, 2) + 3
      let prev = lengths[i - 1]
      for _ in 0..<repeat_count {
        if i >= total {
          raise CompressError::CorruptInput("too many code lengths")
        }
        lengths[i] = prev
        i += 1
      }
    } else if sym == 17 {
      // Repeat zero 3-10 times
      let repeat_count = read_bits(bit_buf, bit_count, data, pos, 3) + 3
      for _ in 0..<repeat_count {
        if i >= total {
          raise CompressError::CorruptInput("too many code lengths")
        }
        lengths[i] = 0
        i += 1
      }
    } else if sym == 18 {
      // Repeat zero 11-138 times
      let repeat_count = read_bits(bit_buf, bit_count, data, pos, 7) + 11
      for _ in 0..<repeat_count {
        if i >= total {
          raise CompressError::CorruptInput("too many code lengths")
        }
        lengths[i] = 0
        i += 1
      }
    } else {
      raise CompressError::CorruptInput("invalid code length symbol \{sym}")
    }
  }
  // Split into literal and distance lengths
  let lit_lengths = FixedArray::make(hlit, 0)
  for j in 0..<hlit {
    lit_lengths[j] = lengths[j]
  }
  let dist_lengths = FixedArray::make(hdist, 0)
  for j in 0..<hdist {
    dist_lengths[j] = lengths[hlit + j]
  }
  let lit_dec = HuffmanDecoder::build(lit_lengths)
  let dist_dec = HuffmanDecoder::build(dist_lengths)
  (lit_dec, dist_dec)
}
