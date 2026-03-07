///|
/// Streaming decompression of DEFLATE data from a reader to a writer.
/// Both input and output stream with constant memory usage.
/// Returns any bytes that were read from source but not consumed by DEFLATE.
pub async fn decompress_to(source : &@io.Reader, dest : &@io.Writer) -> Bytes {
  decompress_to_with_dict(source, dest, Bytes::default())
}

///|
/// Streaming decompression of DEFLATE data with a preset dictionary.
/// Returns any bytes that were read from source but not consumed by DEFLATE.
pub async fn decompress_to_with_dict(
  source : &@io.Reader,
  dest : &@io.Writer,
  dict : Bytes,
) -> Bytes {
  let dd = DictDecoder::new()
  if dict.length() > 0 {
    dd.init_dict(dict)
  }
  let br = AsyncBitReader::new(source)
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
      0 => async_decode_stored_block(dd, dest, br)
      1 =>
        async_decode_huffman_block(
          dd, dest, br, fixed_lit_decoder, fixed_dist_decoder,
        )
      2 => {
        let (lit_dec, dist_dec) = async_read_dynamic_header(br)
        async_decode_huffman_block(dd, dest, br, lit_dec, dist_dec)
      }
      _ => raise CompressError::CorruptInput("invalid block type \{btype}")
    }
  }
  dd.flush_to_writer(dest)
  br.remaining_bytes()
}

///|
async fn async_decode_stored_block(
  dd : DictDecoder,
  dest : &@io.Writer,
  br : AsyncBitReader,
) -> Unit {
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
  for _ in 0..<len {
    let b = br.read(8).to_byte()
    dd.write_byte(b)
    if dd.avail_write() == 0 {
      dd.flush_to_writer(dest)
    }
  }
}

///|
async fn async_decode_huffman_block(
  dd : DictDecoder,
  dest : &@io.Writer,
  br : AsyncBitReader,
  lit_dec : HuffmanDecoder,
  dist_dec : HuffmanDecoder,
) -> Unit {
  let chunk_mask = (1UL << HUFFMAN_CHUNK_BITS) - 1UL
  let lit_chunks = lit_dec.chunks
  while true {
    br.fill()
    let idx = (br.buf & chunk_mask).to_int()
    let entry = lit_chunks[idx]
    let sym = if (entry & 0x80U) == 0U &&
      br.count >= (entry & 0xFFU).reinterpret_as_int() {
      let n = (entry & 0xFFU).reinterpret_as_int()
      let s = (entry >> 8).reinterpret_as_int()
      br.buf = br.buf >> n
      br.count -= n
      s
    } else {
      lit_dec.async_decode(br)
    }
    if sym < 256 {
      dd.write_byte(sym.to_byte())
      if dd.avail_write() == 0 {
        dd.flush_to_writer(dest)
      }
    } else if sym == END_BLOCK_MARKER {
      dd.flush_to_writer(dest)
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
      br.fill()
      let dist_chunks = dist_dec.chunks
      let dist_idx = (br.buf & chunk_mask).to_int()
      let dist_entry = dist_chunks[dist_idx]
      let dist_sym = if (dist_entry & 0x80U) == 0U &&
        br.count >= (dist_entry & 0xFFU).reinterpret_as_int() {
        let n = (dist_entry & 0xFFU).reinterpret_as_int()
        let s = (dist_entry >> 8).reinterpret_as_int()
        br.buf = br.buf >> n
        br.count -= n
        s
      } else {
        dist_dec.async_decode(br)
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
        if dd.avail_write() == 0 {
          dd.flush_to_writer(dest)
        }
      }
    }
  }
}

///|
async fn async_read_dynamic_header(
  br : AsyncBitReader,
) -> (HuffmanDecoder, HuffmanDecoder) {
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
    let sym = cl_decoder.async_decode(br)
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

///|
/// Decodes a single Huffman symbol from an AsyncBitReader.
async fn HuffmanDecoder::async_decode(
  self : HuffmanDecoder,
  br : AsyncBitReader,
) -> Int {
  while br.count < self.max_bits {
    if br.eof {
      if br.count >= self.min_bits {
        break
      }
      raise CompressError::UnexpectedEOF
    }
    let n = br.source.read(br.read_buf, offset=0, max_len=1)
    if n == 0 {
      br.eof = true
      if br.count >= self.min_bits {
        break
      }
      raise CompressError::UnexpectedEOF
    }
    br.buf = br.buf | (br.read_buf[0].to_uint64() << br.count)
    br.count += 8
  }
  let idx = (br.buf & ((1UL << HUFFMAN_CHUNK_BITS) - 1UL)).to_int()
  let entry = self.chunks[idx]
  if (entry & 0x80U) == 0U {
    let n = (entry & 0xFFU).reinterpret_as_int()
    let sym = (entry >> 8).reinterpret_as_int()
    br.buf = br.buf >> n
    br.count -= n
    return sym
  }
  let link_idx = (entry >> 8).reinterpret_as_int()
  let link_table = self.links[link_idx]
  let suffix = (br.buf >> HUFFMAN_CHUNK_BITS).to_int() &
    ((1 << (self.max_bits - HUFFMAN_CHUNK_BITS)) - 1)
  let link_entry = link_table[suffix]
  if link_entry == 0U {
    raise CompressError::CorruptInput("invalid Huffman code")
  }
  let n = (link_entry & 0xFFU).reinterpret_as_int()
  let sym = (link_entry >> 8).reinterpret_as_int()
  br.buf = br.buf >> n
  br.count -= n
  sym
}
