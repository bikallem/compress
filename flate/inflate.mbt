///|
/// Decompresses DEFLATE-encoded data (RFC 1951).
pub fn decompress(data : Bytes) -> Bytes raise CompressError {
  decompress_core(data, Bytes::default()).0
}

///|
/// Decompresses DEFLATE-encoded data with a preset dictionary.
pub fn decompress_with_dict(
  data : Bytes,
  dict : Bytes,
) -> Bytes raise CompressError {
  decompress_core(data, dict).0
}

///|
/// Core decompression returning both result and unconsumed input bytes.
/// The remaining bytes are useful for wrapper formats (gzip, zlib) that
/// need to read a footer after the DEFLATE stream.
fn decompress_core(
  data : Bytes,
  dict : Bytes,
) -> (Bytes, Bytes) raise CompressError {
  let out = @buffer.new(size_hint=data.length() * 2)
  let dd = DictDecoder::new()
  if dict.length() > 0 {
    dd.init_dict(dict)
  }
  let br = BitReader::new(data)
  let mut final_block = false
  while not(final_block) {
    br.ensure(3)
    let bfinal = (br.buf & 1UL).to_int()
    br.buf = br.buf >> 1
    br.count -= 1
    final_block = bfinal != 0
    let btype = (br.buf & 3UL).to_int()
    br.buf = br.buf >> 2
    br.count -= 2
    match btype {
      0 => decode_stored_block(dd, out, br)
      1 =>
        decode_huffman_block(dd, out, br, fixed_lit_decoder, fixed_dist_decoder)
      2 => {
        let (lit_dec, dist_dec) = read_dynamic_header(br)
        decode_huffman_block(dd, out, br, lit_dec, dist_dec)
      }
      _ => raise CompressError::CorruptInput("invalid block type \{btype}")
    }
  }
  dd.read_flush(out)
  (out.to_bytes(), br.remaining_bytes())
}

///|
fn decode_stored_block(
  dd : DictDecoder,
  out : @buffer.Buffer,
  br : BitReader,
) -> Unit raise CompressError {
  let discard = br.count % 8
  if discard > 0 {
    br.buf = br.buf >> discard
    br.count -= discard
  }
  let len = br.read(16)
  let nlen = br.read(16)
  if (len ^ nlen) != 0xFFFF {
    raise CompressError::CorruptInput("invalid stored block lengths")
  }
  // Drain any buffered whole bytes first
  let mut remaining = len
  while remaining > 0 && br.count >= 8 {
    dd.write_byte((br.buf & 0xFFUL).to_byte())
    br.buf = br.buf >> 8
    br.count -= 8
    remaining -= 1
    if dd.avail_write() == 0 {
      dd.read_flush(out)
    }
  }
  // Bulk copy remaining directly from input data
  while remaining > 0 {
    let avail = dd.avail_write()
    let n = if remaining < avail { remaining } else { avail }
    let hist = dd.hist
    for i in 0..<n {
      hist[dd.wr_pos + i] = br.data[br.pos + i]
    }
    dd.wr_pos += n
    br.pos += n
    remaining -= n
    if dd.avail_write() == 0 {
      dd.read_flush(out)
    }
  }
}

///|
fn decode_huffman_block(
  dd : DictDecoder,
  out : @buffer.Buffer,
  br : BitReader,
  lit_dec : HuffmanDecoder,
  dist_dec : HuffmanDecoder,
) -> Unit raise CompressError {
  let chunk_mask = (1UL << HUFFMAN_CHUNK_BITS) - 1UL
  let lit_chunks = lit_dec.chunks
  let dist_chunks = dist_dec.chunks
  let hist = dd.hist
  let hist_len = hist.length()
  while true {
    // Fill bit buffer
    br.fill()
    // Inline Huffman decode for literal/length
    // Safety: chunk_mask bounds index to table size
    let entry = lit_chunks.unsafe_get((br.buf & chunk_mask).to_int())
    let sym = if (entry & 0x80U) == 0U &&
      br.count >= (entry & 0xFFU).reinterpret_as_int() {
      // Direct chunk hit — most common path
      let n = (entry & 0xFFU).reinterpret_as_int()
      let s = (entry >> 8).reinterpret_as_int()
      br.buf = br.buf >> n
      br.count -= n
      s
    } else if (entry & 0x80U) != 0U {
      // Link table path — inlined to avoid function call
      let link_idx = (entry >> 8).reinterpret_as_int()
      let link_table = lit_dec.links.unsafe_get(link_idx)
      let suffix = (br.buf >> HUFFMAN_CHUNK_BITS).to_int() &
        ((1 << (lit_dec.max_bits - HUFFMAN_CHUNK_BITS)) - 1)
      let link_entry = link_table.unsafe_get(suffix)
      let n = (link_entry & 0xFFU).reinterpret_as_int()
      let s = (link_entry >> 8).reinterpret_as_int()
      br.buf = br.buf >> n
      br.count -= n
      s
    } else {
      // Insufficient bits — fallback to full decode with refill
      lit_dec.decode(br)
    }
    if sym < 256 {
      // Safety: wr_pos < hist_len checked via flush at hist_len
      hist.unsafe_set(dd.wr_pos, sym.to_byte())
      dd.wr_pos += 1
      if dd.wr_pos == hist_len {
        dd.read_flush(out)
      }
    } else if sym == END_BLOCK_MARKER {
      dd.read_flush(out)
      return
    } else {
      let length_code = sym - 257
      if length_code >= length_base.length() {
        raise CompressError::CorruptInput("invalid length code \{sym}")
      }
      let extra = length_extra[length_code]
      let extra_val = if extra > 0 {
        br.ensure(extra)
        let mask = (1UL << extra) - 1UL
        let val = (br.buf & mask).to_int()
        br.buf = br.buf >> extra
        br.count -= extra
        val
      } else {
        0
      }
      let length = length_base[length_code] + extra_val
      // Decode distance — fully inlined
      br.fill()
      // Safety: chunk_mask bounds index to table size
      let dist_entry = dist_chunks.unsafe_get((br.buf & chunk_mask).to_int())
      let dist_sym = if (dist_entry & 0x80U) == 0U &&
        br.count >= (dist_entry & 0xFFU).reinterpret_as_int() {
        let n = (dist_entry & 0xFFU).reinterpret_as_int()
        let s = (dist_entry >> 8).reinterpret_as_int()
        br.buf = br.buf >> n
        br.count -= n
        s
      } else if (dist_entry & 0x80U) != 0U {
        let link_idx = (dist_entry >> 8).reinterpret_as_int()
        let link_table = dist_dec.links.unsafe_get(link_idx)
        let suffix = (br.buf >> HUFFMAN_CHUNK_BITS).to_int() &
          ((1 << (dist_dec.max_bits - HUFFMAN_CHUNK_BITS)) - 1)
        let link_entry = link_table.unsafe_get(suffix)
        let n = (link_entry & 0xFFU).reinterpret_as_int()
        let s = (link_entry >> 8).reinterpret_as_int()
        br.buf = br.buf >> n
        br.count -= n
        s
      } else {
        dist_dec.decode(br)
      }
      if dist_sym >= dist_base.length() {
        raise CompressError::CorruptInput("invalid distance code \{dist_sym}")
      }
      let dextra = dist_extra[dist_sym]
      let dextra_val = if dextra > 0 {
        br.ensure(dextra)
        let mask = (1UL << dextra) - 1UL
        let val = (br.buf & mask).to_int()
        br.buf = br.buf >> dextra
        br.count -= dextra
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
      let mut remaining = length
      while remaining > 0 {
        let n = dd.write_copy(dist, remaining)
        remaining -= n
        if dd.wr_pos == hist_len {
          dd.read_flush(out)
        }
      }
    }
  }
}

///|
fn read_dynamic_header(
  br : BitReader,
) -> (HuffmanDecoder, HuffmanDecoder) raise CompressError {
  let hlit = br.read(5) + 257
  let hdist = br.read(5) + 1
  let hclen = br.read(4) + 4
  let cl_lengths = FixedArray::make(NUM_CODES, 0)
  for i in 0..<hclen {
    cl_lengths[code_order[i]] = br.read(3)
  }
  let cl_decoder = HuffmanDecoder::build(cl_lengths)
  let total = hlit + hdist
  let lengths = FixedArray::make(total, 0)
  let mut i = 0
  while i < total {
    let sym = cl_decoder.decode(br)
    if sym < 16 {
      lengths[i] = sym
      i += 1
    } else if sym == 16 {
      guard i > 0 else {
        raise CompressError::CorruptInput("repeat with no previous length")
      }
      let repeat_count = br.read(2) + 3
      let prev = lengths[i - 1]
      for _ in 0..<repeat_count {
        if i >= total {
          raise CompressError::CorruptInput("too many code lengths")
        }
        lengths[i] = prev
        i += 1
      }
    } else if sym == 17 {
      let repeat_count = br.read(3) + 3
      for _ in 0..<repeat_count {
        if i >= total {
          raise CompressError::CorruptInput("too many code lengths")
        }
        lengths[i] = 0
        i += 1
      }
    } else if sym == 18 {
      let repeat_count = br.read(7) + 11
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
