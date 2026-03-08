///|
/// Decompresses DEFLATE data from reader to writer in streaming fashion.
/// Memory usage is constant (~72KB: 32KB window + 32KB BitReader buffer + overhead).
/// Returns unconsumed bytes from the input stream (useful for wrapper formats).
fn decompress_to_writer(
  reader : &@stream.Reader,
  writer : &@stream.Writer,
  dict : Bytes,
) -> Bytes raise {
  let dd = DictDecoder::new()
  if dict.length() > 0 {
    dd.init_dict(dict)
  }
  let br = BitReader::new(reader)
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
      0 => decode_stored_block_streaming(dd, writer, br)
      1 =>
        decode_huffman_block_streaming(
          dd, writer, br, fixed_lit_decoder, fixed_dist_decoder,
        )
      2 => {
        let (lit_dec, dist_dec) = read_dynamic_header(br)
        decode_huffman_block_streaming(dd, writer, br, lit_dec, dist_dec)
      }
      _ => raise CompressError::CorruptInput("invalid block type \{btype}")
    }
  }
  dd.flush_to_writer(writer)
  br.remaining_bytes()
}

///|
fn decode_stored_block_streaming(
  dd : DictDecoder,
  writer : &@stream.Writer,
  br : BitReader,
) -> Unit raise {
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
  let mut remaining = len
  while remaining > 0 && br.count >= 8 {
    dd.write_byte((br.buf & 0xFFUL).to_byte())
    br.buf = br.buf >> 8
    br.count -= 8
    remaining -= 1
    if dd.avail_write() == 0 {
      dd.flush_to_writer(writer)
    }
  }
  while remaining > 0 {
    let avail = dd.avail_write()
    let max = if remaining < avail { remaining } else { avail }
    let chunk = br.next_chunk(max)
    let n = chunk.length()
    let hist = dd.hist
    for i in 0..<n {
      hist[dd.wr_pos + i] = chunk[i]
    }
    dd.wr_pos += n
    remaining -= n
    if dd.avail_write() == 0 {
      dd.flush_to_writer(writer)
    }
  }
}

///|
fn decode_huffman_block_streaming(
  dd : DictDecoder,
  writer : &@stream.Writer,
  br : BitReader,
  lit_dec : HuffmanDecoder,
  dist_dec : HuffmanDecoder,
) -> Unit raise {
  let chunk_mask = (1UL << HUFFMAN_CHUNK_BITS) - 1UL
  let lit_chunks = lit_dec.chunks
  let dist_chunks = dist_dec.chunks
  let hist = dd.hist
  let hist_len = hist.length()
  while true {
    br.fill()
    let entry = lit_chunks.unsafe_get((br.buf & chunk_mask).to_int())
    let sym = if (entry & 0x80U) == 0U &&
      br.count >= (entry & 0xFFU).reinterpret_as_int() {
      let n = (entry & 0xFFU).reinterpret_as_int()
      let s = (entry >> 8).reinterpret_as_int()
      br.buf = br.buf >> n
      br.count -= n
      s
    } else if (entry & 0x80U) != 0U {
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
      lit_dec.decode(br)
    }
    if sym < 256 {
      hist.unsafe_set(dd.wr_pos, sym.to_byte())
      dd.wr_pos += 1
      if dd.wr_pos == hist_len {
        dd.flush_to_writer(writer)
      }
    } else if sym == END_BLOCK_MARKER {
      dd.flush_to_writer(writer)
      return
    } else {
      let length_code = sym - 257
      if length_code >= length_base.length() {
        raise CompressError::CorruptInput("invalid length code \{sym}")
      }
      let extra = length_extra.unsafe_get(length_code)
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
      let length = length_base.unsafe_get(length_code) + extra_val
      br.fill()
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
      let dextra = dist_extra.unsafe_get(dist_sym)
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
      let dist = dist_base.unsafe_get(dist_sym) + dextra_val
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
          dd.flush_to_writer(writer)
        }
      }
    }
  }
}
