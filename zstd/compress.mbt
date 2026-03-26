///|
/// Compresses data using the Zstandard format.
/// Uses LZ77 match finding and zstd compressed blocks.
pub fn compress(
  data : Bytes,
  level? : CompressionLevel = Default,
  dict? : Bytes = Bytes::default(),
) -> Bytes raise ZstdError {
  let parsed_dict = parse_dictionary_for_encoder(dict)
  let src = data[:]
  let src_len = data.length()
  let max_out = 18 + src_len + (src_len / MAX_BLOCK_SIZE + 1) * 6 + 4
  let out = FixedArray::make(max_out, b'\x00')
  let mut pos = 0
  let mut prev_lit_table = parsed_dict.lit_table
  let mut prev_seq_tables = parsed_dict.seq_tables
  pos += write_zstd_frame_header(out, pos, src_len, parsed_dict.dict_id)
  let xxh = @checksum.XXH64::new()
  xxh.update(src)
  if src_len == 0 {
    pos = write_block_header_fixed(out, pos, true, BLOCK_TYPE_RAW, 0)
  } else if parsed_dict.content.length() == 0 && is_all_same(src) {
    let block_header = 1 | (BLOCK_TYPE_RLE << 1) | (src_len << 3)
    out.unsafe_set(pos, (block_header & 0xFF).to_byte())
    out.unsafe_set(pos + 1, ((block_header >> 8) & 0xFF).to_byte())
    out.unsafe_set(pos + 2, ((block_header >> 16) & 0xFF).to_byte())
    pos += 3
    out.unsafe_set(pos, src.unsafe_get(0))
    pos += 1
  } else {
    let (sequences, literals, lit_count) = find_sequences_with_prefix(
      src,
      parsed_dict.content[:],
      copy_rep_offsets(parsed_dict.rep),
      level,
    )
    if sequences.length() == 0 {
      let mut src_pos = 0
      while src_pos < src_len {
        let block_end = if src_pos + MAX_BLOCK_SIZE < src_len {
          src_pos + MAX_BLOCK_SIZE
        } else {
          src_len
        }
        let block_len = block_end - src_pos
        let is_last = block_end == src_len
        let block_bytes = src[src_pos:block_end]
        let block_literals = fixed_array_from_bytesview(block_bytes)
        let comp_buf = FixedArray::make(block_len * 2 + 64, b'\x00')
        let (comp_size, next_lit, next_seq) = compress_literal_only_block(
          block_literals, 0, block_len, comp_buf, prev_lit_table, prev_seq_tables,
        )
        if comp_size > 0 && comp_size < block_len {
          pos = write_block_header_fixed(
            out,
            pos,
            is_last,
            BLOCK_TYPE_COMPRESSED,
            comp_size,
          )
          for i in 0..<comp_size {
            out.unsafe_set(pos + i, comp_buf.unsafe_get(i))
          }
          pos += comp_size
          prev_lit_table = next_lit
          prev_seq_tables = next_seq
        } else {
          pos = write_block_header_fixed(
            out,
            pos,
            is_last,
            BLOCK_TYPE_RAW,
            block_len,
          )
          for i in 0..<block_len {
            out.unsafe_set(pos + i, src.unsafe_get(src_pos + i))
          }
          pos += block_len
        }
        src_pos = block_end
      }
    } else {
      let split_seqs : Array[ZstdSequence] = []
      for i in 0..<sequences.length() {
        let seq = sequences.unsafe_get(i)
        let seq_decoded = seq.lit_len + seq.match_len
        if seq_decoded <= MAX_BLOCK_SIZE {
          split_seqs.push(seq)
        } else {
          let actual_off = seq.actual_offset
          let mut remaining_match = seq.match_len
          let mut first = true
          while remaining_match > 0 {
            let lit_len = if first { seq.lit_len } else { 0 }
            let max_match = MAX_BLOCK_SIZE - lit_len
            let match_chunk = if remaining_match > max_match {
              max_match
            } else {
              remaining_match
            }
            let offset = if first { seq.offset } else { actual_off + 3 }
            split_seqs.push({
              lit_len,
              offset,
              match_len: match_chunk,
              actual_offset: actual_off,
            })
            remaining_match -= match_chunk
            first = false
          }
        }
      }
      let num_seq = split_seqs.length()
      let mut seq_idx = 0
      let mut lit_offset = 0
      let mut decoded_total = 0
      while seq_idx < num_seq {
        let block_seqs : Array[ZstdSequence] = []
        let mut block_decoded = 0
        let block_lit_start = lit_offset
        let mut block_lit_count = 0
        while seq_idx < num_seq {
          let seq = split_seqs.unsafe_get(seq_idx)
          let seq_decoded = seq.lit_len + seq.match_len
          if block_decoded + seq_decoded > MAX_BLOCK_SIZE &&
            block_seqs.length() > 0 {
            break
          }
          block_seqs.push(seq)
          block_decoded += seq_decoded
          block_lit_count += seq.lit_len
          lit_offset += seq.lit_len
          seq_idx += 1
        }
        let mut trailing_lit_count = 0
        if seq_idx >= num_seq {
          trailing_lit_count = lit_count - lit_offset
        }
        let total_block_lits = block_lit_count + trailing_lit_count
        let block_content_size = block_decoded + trailing_lit_count
        decoded_total += block_content_size
        let is_last = seq_idx >= num_seq
        let comp_buf = FixedArray::make(block_content_size * 2 + 256, b'\x00')
        let (comp_size, next_lit, next_seq) = compress_block_from_sequences(
          block_seqs, literals, block_lit_start, total_block_lits, comp_buf, prev_lit_table,
          prev_seq_tables,
        )
        if comp_size > 0 && comp_size < block_content_size {
          pos = write_block_header_fixed(
            out,
            pos,
            is_last,
            BLOCK_TYPE_COMPRESSED,
            comp_size,
          )
          for i in 0..<comp_size {
            out.unsafe_set(pos + i, comp_buf.unsafe_get(i))
          }
          pos += comp_size
          prev_lit_table = next_lit
          prev_seq_tables = next_seq
        } else {
          let raw_start = decoded_total - block_content_size
          pos = write_block_header_fixed(
            out,
            pos,
            is_last,
            BLOCK_TYPE_RAW,
            block_content_size,
          )
          for i in 0..<block_content_size {
            out.unsafe_set(pos + i, src.unsafe_get(raw_start + i))
          }
          pos += block_content_size
        }
        if trailing_lit_count > 0 {
          lit_offset += trailing_lit_count
        }
      }
    }
  }
  let cs = xxh.checksum64()
  let cs32 = cs.to_uint()
  out.unsafe_set(pos, (cs32 & 0xFFU).to_byte())
  out.unsafe_set(pos + 1, ((cs32 >> 8) & 0xFFU).to_byte())
  out.unsafe_set(pos + 2, ((cs32 >> 16) & 0xFFU).to_byte())
  out.unsafe_set(pos + 3, ((cs32 >> 24) & 0xFFU).to_byte())
  pos += 4
  let result = @blit.make_uninit(pos)
  @blit.blit_fixed_array(result, 0, out, 0, pos)
  result.unsafe_reinterpret_as_bytes()
}

///|
fn fixed_array_from_bytesview(data : BytesView) -> FixedArray[Byte] {
  FixedArray::makei(data.length(), fn(i) { data.unsafe_get(i) })
}

///|
fn is_all_same(data : BytesView) -> Bool {
  if data.length() <= 1 {
    return true
  }
  let first = data.unsafe_get(0)
  for i in 1..<data.length() {
    if data.unsafe_get(i) != first {
      return false
    }
  }
  true
}

///|
fn write_block_header_fixed(
  dst : FixedArray[Byte],
  pos_ : Int,
  is_last : Bool,
  block_type : Int,
  block_size : Int,
) -> Int {
  let last_flag = if is_last { 1 } else { 0 }
  let block_header = last_flag | (block_type << 1) | (block_size << 3)
  dst.unsafe_set(pos_, (block_header & 0xFF).to_byte())
  dst.unsafe_set(pos_ + 1, ((block_header >> 8) & 0xFF).to_byte())
  dst.unsafe_set(pos_ + 2, ((block_header >> 16) & 0xFF).to_byte())
  pos_ + 3
}

// ── LZ77 match finder ──────────────────────────────────────────────

///|
const ZSTD_HASH_BITS : Int = 14

///|
const ZSTD_HASH_SIZE : Int = 16384

///|
const ZSTD_MAX_HASH_CANDIDATES : Int = 8

///|
const ZSTD_MIN_MATCH : Int = 4

///|
priv struct ZstdSearchConfig {
  lazy_steps : Int
  max_hash_candidates : Int
  nice_match : Int
}

///|
fn zstd_search_config(level : CompressionLevel) -> ZstdSearchConfig {
  match level {
    Fast => { lazy_steps: 0, max_hash_candidates: 1, nice_match: 24 }
    Default => { lazy_steps: 1, max_hash_candidates: 4, nice_match: 48 }
    Best => { lazy_steps: 3, max_hash_candidates: 8, nice_match: 96 }
    Level(n) =>
      if n <= 1 {
        { lazy_steps: 0, max_hash_candidates: 1, nice_match: 24 }
      } else if n <= 4 {
        { lazy_steps: 0, max_hash_candidates: 2, nice_match: 32 }
      } else if n <= 8 {
        { lazy_steps: 1, max_hash_candidates: 4, nice_match: 48 }
      } else if n <= 15 {
        { lazy_steps: 2, max_hash_candidates: 6, nice_match: 72 }
      } else {
        { lazy_steps: 3, max_hash_candidates: 8, nice_match: 96 }
      }
  }
}

///|
fn zstd_hash(data : BytesView, pos : Int) -> Int {
  let u = data.unsafe_get(pos).to_uint() |
    (data.unsafe_get(pos + 1).to_uint() << 8) |
    (data.unsafe_get(pos + 2).to_uint() << 16) |
    (data.unsafe_get(pos + 3).to_uint() << 24)
  let h = u * 0x9E3779B1_U
  (h >> (32 - ZSTD_HASH_BITS)).reinterpret_as_int()
}

///|
fn insert_hash_candidate(
  hash_table : FixedArray[Int],
  hash : Int,
  pos : Int,
) -> Unit {
  let base = hash * ZSTD_MAX_HASH_CANDIDATES
  for slot = ZSTD_MAX_HASH_CANDIDATES - 1; slot > 0; slot = slot - 1 {
    hash_table.unsafe_set(base + slot, hash_table.unsafe_get(base + slot - 1))
  }
  hash_table.unsafe_set(base, pos)
}

///|
fn get_hash_candidate(
  hash_table : FixedArray[Int],
  hash : Int,
  slot : Int,
) -> Int {
  hash_table.unsafe_get(hash * ZSTD_MAX_HASH_CANDIDATES + slot)
}

///|
priv struct ZstdSequence {
  lit_len : Int
  offset : Int // offset_value for encoding (1/2/3 for repeat, actual+3 for new)
  match_len : Int
  actual_offset : Int // the real match offset in bytes (for splitting)
}

///|
priv struct MatchCandidate {
  length : Int
  offset : Int
  rep_idx : Int
}

///|
fn find_sequences_with_prefix(
  src : BytesView,
  prefix : BytesView,
  rep_init : Array[Int],
  level : CompressionLevel,
) -> (Array[ZstdSequence], FixedArray[Byte], Int) {
  let combined = @blit.Buffer::new(size_hint=prefix.length() + src.length())
  if prefix.length() > 0 {
    combined.write_bytesview(prefix)
  }
  combined.write_bytesview(src)
  find_sequences_combined(
    combined.to_bytes(),
    prefix.length(),
    rep_init,
    zstd_search_config(level),
  )
}

///|
fn find_sequences_combined(
  combined : Bytes,
  base : Int,
  rep_init : Array[Int],
  config : ZstdSearchConfig,
) -> (Array[ZstdSequence], FixedArray[Byte], Int) {
  let src = combined[:]
  let src_len = combined.length() - base
  let sequences : Array[ZstdSequence] = []
  let literals = FixedArray::make(src_len, b'\x00')
  let mut lit_pos = 0
  if src_len < ZSTD_MIN_MATCH + 5 {
    for i in 0..<src_len {
      literals.unsafe_set(lit_pos, src.unsafe_get(base + i))
      lit_pos += 1
    }
    return (sequences, literals, lit_pos)
  }
  let hash_table = FixedArray::make(
    ZSTD_HASH_SIZE * ZSTD_MAX_HASH_CANDIDATES,
    -1,
  )
  let rep = copy_rep_offsets(rep_init)
  let mut ip = base
  let mut anchor = base
  let mf_limit = combined.length() - ZSTD_MIN_MATCH
  if base >= ZSTD_MIN_MATCH {
    for i in 0..<(base - ZSTD_MIN_MATCH + 1) {
      insert_hash_candidate(hash_table, zstd_hash(src, i), i)
    }
  }
  while ip < mf_limit {
    let hash = zstd_hash(src, ip)
    let mut match_ip = ip
    let mut best = find_best_match(
      src,
      match_ip,
      combined.length(),
      hash_table,
      hash,
      rep,
      config,
    )
    insert_hash_candidate(hash_table, hash, ip)
    let mut lazy_steps = config.lazy_steps
    while lazy_steps > 0 &&
          best.length >= ZSTD_MIN_MATCH &&
          best.length < config.nice_match &&
          match_ip + 1 < mf_limit {
      let next_ip = match_ip + 1
      let next_hash = zstd_hash(src, next_ip)
      let next_best = find_best_match(
        src,
        next_ip,
        combined.length(),
        hash_table,
        next_hash,
        rep,
        config,
      )
      insert_hash_candidate(hash_table, next_hash, next_ip)
      if next_best.length > best.length + 1 {
        match_ip = next_ip
        best = next_best
        lazy_steps -= 1
        continue
      }
      break
    }
    if best.length >= ZSTD_MIN_MATCH {
      let lit_len = match_ip - anchor
      for i in 0..<lit_len {
        literals.unsafe_set(lit_pos, src.unsafe_get(anchor + i))
        lit_pos += 1
      }
      // Determine offset_value for zstd encoding, accounting for lit_len==0 special cases.
      // The decoder interprets offset_value based on lit_len:
      //   lit_len > 0: val 1 => rep[0], val 2 => rep[1], val 3 => rep[2]
      //   lit_len == 0: val 1 => rep[1], val 2 => rep[2], val 3 => rep[0]-1
      let offset_value = if best.rep_idx >= 0 {
        if lit_len > 0 {
          best.rep_idx + 1
          // lit_len == 0: shift the mapping
        } else if best.rep_idx == 0 {
          // Want rep[0], but val 1 means rep[1] when lit_len==0
          // Need to check if rep[0] == rep[1]; if so val 1 works
          // Otherwise emit as new offset to be safe
          if rep.unsafe_get(0) == rep.unsafe_get(1) {
            1
          } else {
            rep.unsafe_get(0) + 3 // emit as new offset
          }
        } else if best.rep_idx == 1 {
          1 // val 1 with lit_len==0 => rep[1], which is what we want
        } else {
          2 // val 2 with lit_len==0 => rep[2], which is what we want
        }
      } else {
        best.offset + 3 // actual offset + 3 for new offsets
      }
      let actual_off = resolve_offset(rep, offset_value, lit_len)
      sequences.push({
        lit_len,
        offset: offset_value,
        match_len: best.length,
        actual_offset: actual_off,
      })
      // Update hash table for positions within the match for better future matches
      let hash_end = if match_ip + best.length < mf_limit {
        match_ip + best.length
      } else {
        mf_limit
      }
      for j = match_ip + 1; j < hash_end; j = j + 1 {
        let h = zstd_hash(src, j)
        insert_hash_candidate(hash_table, h, j)
      }
      ip = match_ip + best.length
      anchor = ip
      continue
    }
    ip += 1
  }
  let trailing = combined.length() - anchor
  for i in 0..<trailing {
    literals.unsafe_set(lit_pos, src.unsafe_get(anchor + i))
    lit_pos += 1
  }
  (sequences, literals, lit_pos)
}

///|
fn find_best_match(
  src : BytesView,
  ip : Int,
  src_end : Int,
  hash_table : FixedArray[Int],
  hash : Int,
  rep : Array[Int],
  config : ZstdSearchConfig,
) -> MatchCandidate {
  let mut best = { length: 0, offset: 0, rep_idx: -1 }
  for r in 0..<3 {
    let rep_off = rep.unsafe_get(r)
    if ip >= rep_off &&
      ip + ZSTD_MIN_MATCH <= src_end &&
      src.unsafe_get(ip - rep_off) == src.unsafe_get(ip) &&
      src.unsafe_get(ip - rep_off + 1) == src.unsafe_get(ip + 1) &&
      src.unsafe_get(ip - rep_off + 2) == src.unsafe_get(ip + 2) &&
      src.unsafe_get(ip - rep_off + 3) == src.unsafe_get(ip + 3) {
      let mut mlen = ZSTD_MIN_MATCH
      while ip + mlen < src_end &&
            src.unsafe_get(ip - rep_off + mlen) == src.unsafe_get(ip + mlen) {
        mlen += 1
      }
      if mlen > best.length {
        best = { length: mlen, offset: rep_off, rep_idx: r }
        if mlen >= config.nice_match {
          return best
        }
      }
    }
  }
  for slot in 0..<config.max_hash_candidates {
    let ref_pos = get_hash_candidate(hash_table, hash, slot)
    if ref_pos < 0 || ref_pos >= ip {
      continue
    }
    let hash_offset = ip - ref_pos
    if hash_offset > MAX_WINDOW_SIZE {
      continue
    }
    if src.unsafe_get(ref_pos) == src.unsafe_get(ip) &&
      src.unsafe_get(ref_pos + 1) == src.unsafe_get(ip + 1) &&
      src.unsafe_get(ref_pos + 2) == src.unsafe_get(ip + 2) &&
      src.unsafe_get(ref_pos + 3) == src.unsafe_get(ip + 3) {
      let mut match_len = ZSTD_MIN_MATCH
      while ip + match_len < src_end &&
            src.unsafe_get(ref_pos + match_len) ==
            src.unsafe_get(ip + match_len) {
        match_len += 1
      }
      if match_len > best.length + 1 || best.rep_idx < 0 {
        if match_len > best.length || best.rep_idx < 0 {
          best = { length: match_len, offset: hash_offset, rep_idx: -1 }
          if match_len >= config.nice_match {
            break
          }
        }
      }
    }
  }
  best
}

// ── FSE CTable (compression table) ─────────────────────────────────

///|
/// Per-symbol compression transform parameters, matching the reference
/// FSE_symbolCompressionTransform struct.
priv struct FseSymbolTT {
  delta_nb_bits : Int
  delta_find_state : Int
}

///|
/// FSE compression table.
priv struct FseCTable {
  state_table : FixedArray[Int]
  symbol_tt : FixedArray[FseSymbolTT]
  table_log : Int
}

///|
/// Build an FSE CTable from normalized counts.
fn build_fse_ctable(
  norm_counts : FixedArray[Int],
  max_symbol : Int,
  table_log : Int,
) -> FseCTable {
  let table_size = 1 << table_log
  // Spread symbols (same algorithm as decode table)
  let decode_symbols = FixedArray::make(table_size, 0)
  let mut high_threshold = table_size - 1
  for sym in 0..<=max_symbol {
    if norm_counts.unsafe_get(sym) == -1 {
      decode_symbols.unsafe_set(high_threshold, sym)
      high_threshold -= 1
    }
  }
  let step = (table_size >> 1) + (table_size >> 3) + 3
  let mask = table_size - 1
  let mut pos = 0
  for sym in 0..<=max_symbol {
    let count = norm_counts.unsafe_get(sym)
    if count <= 0 {
      continue
    }
    for _ in 0..<count {
      decode_symbols.unsafe_set(pos, sym)
      pos = (pos + step) & mask
      while pos > high_threshold {
        pos = (pos + step) & mask
      }
    }
  }
  // Build symbolTT (per-symbol transform parameters)
  let symbol_tt = FixedArray::make(max_symbol + 1, {
    delta_nb_bits: 0,
    delta_find_state: 0,
  })
  let mut total = 0
  for sym in 0..<=max_symbol {
    let count = norm_counts.unsafe_get(sym)
    if count == 0 {
      continue
    }
    if count == -1 || count == 1 {
      symbol_tt.unsafe_set(sym, {
        delta_nb_bits: (table_log << 16) - (1 << table_log),
        delta_find_state: total - 1,
      })
      total += 1
    } else {
      let max_bits_out = table_log - (highest_bit(count - 1) - 1)
      let min_state_plus = count << max_bits_out
      symbol_tt.unsafe_set(sym, {
        delta_nb_bits: (max_bits_out << 16) - min_state_plus,
        delta_find_state: total - count,
      })
      total += count
    }
  }
  // Build state table
  let state_table = FixedArray::make(table_size, 0)
  let cum = FixedArray::make(max_symbol + 1, 0)
  // Compute cumulative positions
  let mut c = 0
  for sym in 0..<=max_symbol {
    let count = norm_counts.unsafe_get(sym)
    if count == 0 {
      cum.unsafe_set(sym, c)
      continue
    }
    cum.unsafe_set(sym, c)
    c += if count == -1 { 1 } else { count }
  }
  // Fill state table
  let sym_pos = FixedArray::make(max_symbol + 1, 0)
  for sym in 0..<=max_symbol {
    sym_pos.unsafe_set(sym, cum.unsafe_get(sym))
  }
  for i in 0..<table_size {
    let sym = decode_symbols.unsafe_get(i)
    let sp = sym_pos.unsafe_get(sym)
    state_table.unsafe_set(sp, table_size + i)
    sym_pos.unsafe_set(sym, sp + 1)
  }
  { state_table, symbol_tt, table_log }
}

///|
/// FSE encode symbol: output bits from current state, transition to new state.
fn fse_encode_symbol(
  ct : FseCTable,
  bw : FseBitWriter,
  state : Int,
  symbol : Int,
) -> Int {
  let stt = ct.symbol_tt.unsafe_get(symbol)
  let nb_bits_out = (state + stt.delta_nb_bits) >> 16
  bw.add_bits(state, nb_bits_out)
  bw.flush()
  ct.state_table.unsafe_get((state >> nb_bits_out) + stt.delta_find_state)
}

///|
/// Initialize FSE state for a given symbol (FSE_initCState2).
fn fse_init_state(ct : FseCTable, symbol : Int) -> Int {
  let stt = ct.symbol_tt.unsafe_get(symbol)
  let nb_bits_out = (stt.delta_nb_bits + (1 << 15)) >> 16
  let val = (nb_bits_out << 16) - stt.delta_nb_bits
  ct.state_table.unsafe_get((val >> nb_bits_out) + stt.delta_find_state)
}

///|
/// Flush FSE state: write the final state value as table_log bits.
fn fse_flush_state(bw : FseBitWriter, state : Int, table_log : Int) -> Unit {
  bw.add_bits(state, table_log)
  bw.flush()
}

// ── Forward bit writer for FSE encoding ─────────────────────────────

///|
/// Bit writer that accumulates bits LSB-first into a byte buffer.
/// Produces a forward byte stream that is then reversed for the backward format.
priv struct FseBitWriter {
  buf : FixedArray[Byte]
  mut byte_pos : Int
  mut bit_buf : UInt64
  mut bit_pos : Int
}

///|
fn FseBitWriter::new(capacity : Int) -> FseBitWriter {
  {
    buf: FixedArray::make(capacity, b'\x00'),
    byte_pos: 0,
    bit_buf: 0UL,
    bit_pos: 0,
  }
}

///|
fn FseBitWriter::add_bits(self : FseBitWriter, value : Int, nb : Int) -> Unit {
  if nb == 0 {
    return
  }
  let mask = if nb >= 32 { 0xFFFFFFFF_U } else { (1U << nb) - 1U }
  self.bit_buf = self.bit_buf |
    ((value.reinterpret_as_uint() & mask).to_uint64() << self.bit_pos)
  self.bit_pos += nb
}

///|
fn FseBitWriter::flush(self : FseBitWriter) -> Unit {
  while self.bit_pos >= 8 {
    self.buf.unsafe_set(
      self.byte_pos,
      (self.bit_buf & 0xFFUL).to_uint().to_byte(),
    )
    self.byte_pos += 1
    self.bit_buf = self.bit_buf >> 8
    self.bit_pos -= 8
  }
}

///|
/// Close the stream: add sentinel bit, flush remaining bits.
fn FseBitWriter::close(self : FseBitWriter) -> Unit {
  self.add_bits(1, 1)
  if self.bit_pos > 0 {
    self.buf.unsafe_set(
      self.byte_pos,
      (self.bit_buf & 0xFFUL).to_uint().to_byte(),
    )
    self.byte_pos += 1
  }
}

///|
/// Copy bytes to dst (forward order - the backward stream is stored as-is,
/// the backward reader traverses it in reverse).
fn FseBitWriter::copy_to(
  self : FseBitWriter,
  dst : FixedArray[Byte],
  dst_pos : Int,
) -> Int {
  let n = self.byte_pos
  for i in 0..<n {
    dst.unsafe_set(dst_pos + i, self.buf.unsafe_get(i))
  }
  n
}

// ── Offset/LL/ML code computation ───────────────────────────────────

///|
/// Offset encoding: offset field is already the offset_value
/// (1/2/3 for repeat offsets, actual_offset+3 for new offsets).
fn get_offset_code(offset_value : Int) -> (Int, Int, Int) {
  let code = highest_bit(offset_value) - 1
  let extra = offset_value - (1 << code)
  (code, code, extra)
}

///|
fn get_ll_code(ll : Int) -> (Int, Int, Int) {
  if ll < 16 {
    return (ll, 0, 0)
  }
  for code = 35; code >= 16; code = code - 1 {
    if ll >= ll_baselines.unsafe_get(code) {
      return (
        code,
        ll_extra_bits.unsafe_get(code),
        ll - ll_baselines.unsafe_get(code),
      )
    }
  }
  (0, 0, 0)
}

///|
fn get_ml_code(ml : Int) -> (Int, Int, Int) {
  if ml <= 34 {
    return (ml - 3, 0, 0)
  }
  for code = 52; code >= 32; code = code - 1 {
    if ml >= ml_baselines.unsafe_get(code) {
      return (
        code,
        ml_extra_bits.unsafe_get(code),
        ml - ml_baselines.unsafe_get(code),
      )
    }
  }
  (0, 0, 0)
}

// ── Compressed block encoding ───────────────────────────────────────

///|
priv struct HuffmanCodebook {
  codes : FixedArray[Int]
  bits : FixedArray[Int]
  valid : FixedArray[Bool]
}

///|
priv struct SeqEncoderChoice {
  mode : Int
  ctable : FseCTable?
  rle_symbol : Int?
  next_decoder : SeqDecoder
  header : Bytes?
}

///|
priv struct FseNormPlan {
  norm_counts : FixedArray[Int]
  actual_max_symbol : Int
  table_log : Int
}

///|
priv struct LiteralSectionCandidate {
  bytes : Bytes
  size : Int
  next_table : ZstdHuffmanTable?
}

///|
priv struct HuffmanLiteralTableInfo {
  table : ZstdHuffmanTable
  partial_weights : Array[Int]
  highest_symbol : Int
}

///|
/// Encode a block from pre-computed sequences and literals.
fn compress_block_from_sequences(
  sequences : Array[ZstdSequence],
  literals : FixedArray[Byte],
  lit_start : Int,
  lit_count : Int,
  dst : FixedArray[Byte],
  prev_lit_table : ZstdHuffmanTable?,
  prev_seq_tables : SeqTables?,
) -> (Int, ZstdHuffmanTable?, SeqTables?) {
  if sequences.length() == 0 {
    return compress_literal_only_block(
      literals, lit_start, lit_count, dst, prev_lit_table, prev_seq_tables,
    )
  }
  let mut pos = 0
  let (lit_size, next_lit_table) = write_literal_section(
    dst, pos, literals, lit_start, lit_count, prev_lit_table,
  )
  pos += lit_size
  let num_seq = sequences.length()
  pos += write_num_sequences_header(dst, pos, num_seq)
  let ll_codes = FixedArray::make(num_seq, 0)
  let of_codes = FixedArray::make(num_seq, 0)
  let ml_codes = FixedArray::make(num_seq, 0)
  for i in 0..<num_seq {
    let seq = sequences.unsafe_get(i)
    let (ll_code, _, _) = get_ll_code(seq.lit_len)
    let (of_code, _, _) = get_offset_code(seq.offset)
    let (ml_code, _, _) = get_ml_code(seq.match_len)
    ll_codes.unsafe_set(i, ll_code)
    of_codes.unsafe_set(i, of_code)
    ml_codes.unsafe_set(i, ml_code)
  }
  let prev_ll = match prev_seq_tables {
    Some(t) => Some(t.ll)
    None => None
  }
  let prev_of = match prev_seq_tables {
    Some(t) => Some(t.of)
    None => None
  }
  let prev_ml = match prev_seq_tables {
    Some(t) => Some(t.ml)
    None => None
  }
  let ll_choice = select_sequence_encoder(
    ll_codes,
    num_seq,
    35,
    SeqDecoder::Fse(ll_default_table),
    ll_default_norm,
    LL_DEFAULT_ACCURACY,
    prev_ll,
  )
  let of_choice = select_sequence_encoder(
    of_codes,
    num_seq,
    28,
    SeqDecoder::Fse(of_default_table),
    of_default_norm,
    OF_DEFAULT_ACCURACY,
    prev_of,
  )
  let ml_choice = select_sequence_encoder(
    ml_codes,
    num_seq,
    52,
    SeqDecoder::Fse(ml_default_table),
    ml_default_norm,
    ML_DEFAULT_ACCURACY,
    prev_ml,
  )
  let modes = (ll_choice.mode << 6) |
    (of_choice.mode << 4) |
    (ml_choice.mode << 2)
  dst.unsafe_set(pos, modes.to_byte())
  pos += 1
  pos += write_sequence_choice_header(dst, pos, ll_choice)
  pos += write_sequence_choice_header(dst, pos, of_choice)
  pos += write_sequence_choice_header(dst, pos, ml_choice)
  let stream_size = encode_sequences(
    sequences,
    ll_codes,
    of_codes,
    ml_codes,
    ll_choice.ctable,
    ll_choice.rle_symbol,
    of_choice.ctable,
    of_choice.rle_symbol,
    ml_choice.ctable,
    ml_choice.rle_symbol,
    dst,
    pos,
  )
  if stream_size == 0 {
    return (0, next_lit_table, prev_seq_tables)
  }
  pos += stream_size
  (
    pos,
    next_lit_table,
    Some({
      ll: ll_choice.next_decoder,
      of: of_choice.next_decoder,
      ml: ml_choice.next_decoder,
    }),
  )
}

///|
fn compress_literal_only_block(
  literals : FixedArray[Byte],
  lit_start : Int,
  lit_count : Int,
  dst : FixedArray[Byte],
  prev_lit_table : ZstdHuffmanTable?,
  prev_seq_tables : SeqTables?,
) -> (Int, ZstdHuffmanTable?, SeqTables?) {
  let (lit_size, next_lit_table) = write_literal_section(
    dst, 0, literals, lit_start, lit_count, prev_lit_table,
  )
  let pos = lit_size
  dst.unsafe_set(pos, b'\x00')
  (pos + 1, next_lit_table, prev_seq_tables)
}

///|
fn write_num_sequences_header(
  dst : FixedArray[Byte],
  pos_ : Int,
  num_seq : Int,
) -> Int {
  let mut pos = pos_
  if num_seq < 128 {
    dst.unsafe_set(pos, num_seq.to_byte())
    pos += 1
  } else if num_seq < 0x7F00 {
    dst.unsafe_set(pos, ((num_seq >> 8) + 128).to_byte())
    dst.unsafe_set(pos + 1, (num_seq & 0xFF).to_byte())
    pos += 2
  } else {
    dst.unsafe_set(pos, b'\xFF')
    let val = num_seq - 0x7F00
    dst.unsafe_set(pos + 1, (val & 0xFF).to_byte())
    dst.unsafe_set(pos + 2, ((val >> 8) & 0xFF).to_byte())
    pos += 3
  }
  pos - pos_
}

///|
fn write_literal_section(
  dst : FixedArray[Byte],
  pos_ : Int,
  literals : FixedArray[Byte],
  lit_start : Int,
  lit_count : Int,
  prev_lit_table : ZstdHuffmanTable?,
) -> (Int, ZstdHuffmanTable?) {
  let mut pos = pos_
  let use_rle = if lit_count > 1 {
    let first = literals.unsafe_get(lit_start)
    let mut same = true
    for i in 1..<lit_count {
      if literals.unsafe_get(lit_start + i) != first {
        same = false
        break
      }
    }
    same
  } else {
    false
  }
  if use_rle {
    pos += write_raw_literal_header(dst, pos, lit_count, 1)
    dst.unsafe_set(pos, literals.unsafe_get(lit_start))
    pos += 1
    return (pos - pos_, prev_lit_table)
  }
  let raw_section_size = raw_literal_header_size(lit_count) + lit_count
  let mut best : LiteralSectionCandidate? = None
  match prev_lit_table {
    Some(table) => {
      let codebook = build_huffman_codebook(table)
      if codebook_can_encode_literals(codebook, literals, lit_start, lit_count) {
        match
          build_huffman_literal_candidate(
            codebook, literals, lit_start, lit_count, 3, b"", prev_lit_table,
          ) {
          Some(candidate) if candidate.size < raw_section_size =>
            best = Some(candidate)
          _ => ()
        }
      }
    }
    None => ()
  }
  match try_build_custom_literal_candidate(literals, lit_start, lit_count) {
    Some(candidate) => {
      let should_use = if candidate.size >= raw_section_size {
        false
      } else {
        match best {
          Some(current) => candidate.size < current.size
          None => true
        }
      }
      if should_use {
        best = Some(candidate)
      }
    }
    None => ()
  }
  match best {
    Some(candidate) => {
      for i in 0..<candidate.size {
        dst.unsafe_set(pos + i, candidate.bytes[i])
      }
      pos += candidate.size
      (pos - pos_, candidate.next_table)
    }
    None => {
      pos += write_raw_literal_header(dst, pos, lit_count, 0)
      for i in 0..<lit_count {
        dst.unsafe_set(pos + i, literals.unsafe_get(lit_start + i))
      }
      pos += lit_count
      (pos - pos_, prev_lit_table)
    }
  }
}

///|
fn raw_literal_header_size(lit_count : Int) -> Int {
  if lit_count < 32 {
    1
  } else if lit_count < 4096 {
    2
  } else {
    3
  }
}

///|
fn write_raw_literal_header(
  dst : FixedArray[Byte],
  pos_ : Int,
  lit_count : Int,
  lit_type : Int,
) -> Int {
  let mut pos = pos_
  if lit_count < 32 {
    dst.unsafe_set(pos, ((lit_count << 3) | lit_type).to_byte())
    pos += 1
  } else if lit_count < 4096 {
    let header = (lit_count << 4) | (1 << 2) | lit_type
    dst.unsafe_set(pos, (header & 0xFF).to_byte())
    dst.unsafe_set(pos + 1, ((header >> 8) & 0xFF).to_byte())
    pos += 2
  } else {
    let header = (lit_count << 4) | (3 << 2) | lit_type
    dst.unsafe_set(pos, (header & 0xFF).to_byte())
    dst.unsafe_set(pos + 1, ((header >> 8) & 0xFF).to_byte())
    dst.unsafe_set(pos + 2, ((header >> 16) & 0xFF).to_byte())
    pos += 3
  }
  pos - pos_
}

///|
fn try_build_custom_literal_candidate(
  literals : FixedArray[Byte],
  lit_start : Int,
  lit_count : Int,
) -> LiteralSectionCandidate? {
  match build_huffman_literal_table_info(literals, lit_start, lit_count) {
    Some(info) => {
      let codebook = build_huffman_codebook(info.table)
      let mut best : LiteralSectionCandidate? = None
      match write_direct_huffman_table_description(info) {
        Some(table_desc) =>
          match
            build_huffman_literal_candidate(
              codebook,
              literals,
              lit_start,
              lit_count,
              2,
              table_desc,
              Some(info.table),
            ) {
            Some(candidate) => best = Some(candidate)
            None => ()
          }
        None => ()
      }
      match write_fse_huffman_table_description(info) {
        Some(table_desc) =>
          match
            build_huffman_literal_candidate(
              codebook,
              literals,
              lit_start,
              lit_count,
              2,
              table_desc,
              Some(info.table),
            ) {
            Some(candidate) =>
              match best {
                Some(current) if current.size <= candidate.size => ()
                _ => best = Some(candidate)
              }
            None => ()
          }
        None => ()
      }
      best
    }
    None => None
  }
}

///|
fn build_huffman_literal_candidate(
  codebook : HuffmanCodebook,
  literals : FixedArray[Byte],
  lit_start : Int,
  lit_count : Int,
  lit_type : Int,
  table_desc : Bytes,
  next_table : ZstdHuffmanTable?,
) -> LiteralSectionCandidate? {
  let mut best_bytes : Bytes? = None
  let mut best_size = 0
  if lit_count < 1024 {
    let payload = encode_huffman_literals_single_stream(
      codebook, literals, lit_start, lit_count,
    )
    let comp_size = table_desc.length() + payload.length()
    match
      build_huffman_literal_section_bytes(
        lit_type, lit_count, comp_size, 1, table_desc, payload,
      ) {
      Some(section) => {
        best_size = section.length()
        best_bytes = Some(section)
      }
      None => ()
    }
  }
  if lit_count >= 6 {
    let payload = encode_huffman_literals_four_streams(
      codebook, literals, lit_start, lit_count,
    )
    let comp_size = table_desc.length() + payload.length()
    match
      build_huffman_literal_section_bytes(
        lit_type, lit_count, comp_size, 4, table_desc, payload,
      ) {
      Some(section) =>
        if best_size == 0 || section.length() < best_size {
          best_size = section.length()
          best_bytes = Some(section)
        }
      None => ()
    }
  }
  match best_bytes {
    Some(bytes) => Some({ bytes, size: best_size, next_table })
    None => None
  }
}

///|
fn build_huffman_literal_section_bytes(
  lit_type : Int,
  lit_count : Int,
  comp_size : Int,
  num_streams : Int,
  table_desc : Bytes,
  payload : Bytes,
) -> Bytes? {
  let header_size = compressed_literal_header_size(
    lit_count, comp_size, num_streams,
  )
  if header_size == 0 {
    return None
  }
  let total_size = header_size + table_desc.length() + payload.length()
  let out = FixedArray::make(total_size, b'\x00')
  let mut pos = write_compressed_literal_header(
    out, 0, lit_type, lit_count, comp_size, num_streams,
  )
  for i in 0..<table_desc.length() {
    out.unsafe_set(pos + i, table_desc[i])
  }
  pos += table_desc.length()
  for i in 0..<payload.length() {
    out.unsafe_set(pos + i, payload[i])
  }
  Some(fixed_array_prefix_to_bytes(out, total_size))
}

///|
fn encode_huffman_literals_single_stream(
  codebook : HuffmanCodebook,
  literals : FixedArray[Byte],
  lit_start : Int,
  lit_count : Int,
) -> Bytes {
  if lit_count == 0 {
    return b""
  }
  let temp = FixedArray::make(huffman_stream_capacity(lit_count), b'\x00')
  let size = encode_literals_with_codebook(
    codebook, literals, lit_start, lit_count, temp, 0,
  )
  fixed_array_prefix_to_bytes(temp, size)
}

///|
fn encode_huffman_literals_four_streams(
  codebook : HuffmanCodebook,
  literals : FixedArray[Byte],
  lit_start : Int,
  lit_count : Int,
) -> Bytes {
  let chunk_size = (lit_count + 3) >> 2
  let stream4_count = lit_count - 3 * chunk_size
  let s1 = encode_huffman_literals_single_stream(
    codebook, literals, lit_start, chunk_size,
  )
  let s2 = encode_huffman_literals_single_stream(
    codebook,
    literals,
    lit_start + chunk_size,
    chunk_size,
  )
  let s3 = encode_huffman_literals_single_stream(
    codebook,
    literals,
    lit_start + 2 * chunk_size,
    chunk_size,
  )
  let s4 = encode_huffman_literals_single_stream(
    codebook,
    literals,
    lit_start + 3 * chunk_size,
    stream4_count,
  )
  let out = @blit.Buffer::new(
    size_hint=6 + s1.length() + s2.length() + s3.length() + s4.length(),
  )
  write_stream_le_value(out, s1.length().reinterpret_as_uint(), 2)
  write_stream_le_value(out, s2.length().reinterpret_as_uint(), 2)
  write_stream_le_value(out, s3.length().reinterpret_as_uint(), 2)
  out.write_bytes(s1)
  out.write_bytes(s2)
  out.write_bytes(s3)
  out.write_bytes(s4)
  out.to_bytes()
}

///|
fn huffman_stream_capacity(lit_count : Int) -> Int {
  (lit_count * ZSTD_HUFFMAN_MAX_BITS + 7) / 8 + 8
}

///|
fn compressed_literal_header_size(
  lit_count : Int,
  comp_size : Int,
  num_streams : Int,
) -> Int {
  if num_streams == 1 {
    if lit_count < 1024 && comp_size < 1024 {
      return 3
    }
    return 0
  }
  if lit_count < 1024 && comp_size < 1024 {
    3
  } else if lit_count < 16384 && comp_size < 16384 {
    4
  } else if lit_count < 1 << 18 && comp_size < 1 << 18 {
    5
  } else {
    0
  }
}

///|
fn write_compressed_literal_header(
  dst : FixedArray[Byte],
  pos_ : Int,
  lit_type : Int,
  lit_count : Int,
  comp_size : Int,
  num_streams : Int,
) -> Int {
  let mut pos = pos_
  if num_streams == 1 {
    let header = lit_type | (lit_count << 4) | (comp_size << 14)
    pos = write_le_value(dst, pos, header.reinterpret_as_uint(), 3)
    return pos - pos_
  }
  if lit_count < 1024 && comp_size < 1024 {
    let header = lit_type | (1 << 2) | (lit_count << 4) | (comp_size << 14)
    pos = write_le_value(dst, pos, header.reinterpret_as_uint(), 3)
  } else if lit_count < 16384 && comp_size < 16384 {
    let header = lit_type | (2 << 2) | (lit_count << 4) | (comp_size << 18)
    pos = write_le_value(dst, pos, header.reinterpret_as_uint(), 4)
  } else {
    let header = lit_type |
      (3 << 2) |
      (lit_count << 4) |
      ((comp_size & 0x3FF) << 22)
    pos = write_le_value(dst, pos, header.reinterpret_as_uint(), 4)
    dst.unsafe_set(pos, ((comp_size >> 10) & 0xFF).to_byte())
    pos += 1
  }
  pos - pos_
}

///|
fn fixed_array_prefix_to_bytes(arr : FixedArray[Byte], size : Int) -> Bytes {
  Bytes::makei(size, fn(i) { arr.unsafe_get(i) })
}

///|
fn build_huffman_literal_table_info(
  literals : FixedArray[Byte],
  lit_start : Int,
  lit_count : Int,
) -> HuffmanLiteralTableInfo? {
  if lit_count <= 1 {
    return None
  }
  let counts = FixedArray::make(256, 0)
  let mut highest_symbol = -1
  let mut unique = 0
  for i in 0..<lit_count {
    let sym = literals.unsafe_get(lit_start + i).to_int()
    if counts.unsafe_get(sym) == 0 {
      unique += 1
      if sym > highest_symbol {
        highest_symbol = sym
      }
    }
    counts.unsafe_set(sym, counts.unsafe_get(sym) + 1)
  }
  if unique <= 1 || highest_symbol <= 0 {
    return None
  }
  let max_nodes = unique * 2
  let frequencies = FixedArray::make(max_nodes, 0)
  let parents = FixedArray::make(max_nodes, -1)
  let symbols = FixedArray::make(max_nodes, -1)
  let mut leaf_count = 0
  for sym in 0..<=highest_symbol {
    let count = counts.unsafe_get(sym)
    if count > 0 {
      frequencies.unsafe_set(leaf_count, count)
      symbols.unsafe_set(leaf_count, sym)
      leaf_count += 1
    }
  }
  let mut node_count = leaf_count
  while count_root_nodes(parents, node_count) > 1 {
    let first = find_lowest_huffman_node(frequencies, parents, node_count, -1)
    let second = find_lowest_huffman_node(
      frequencies, parents, node_count, first,
    )
    if first < 0 || second < 0 {
      return None
    }
    parents.unsafe_set(first, node_count)
    parents.unsafe_set(second, node_count)
    frequencies.unsafe_set(
      node_count,
      frequencies.unsafe_get(first) + frequencies.unsafe_get(second),
    )
    node_count += 1
  }
  let partial_weights : Array[Int] = []
  let mut table_log = 0
  let depths_by_symbol = FixedArray::make(highest_symbol + 1, 0)
  for leaf in 0..<leaf_count {
    let mut depth = 0
    let mut node = leaf
    while parents.unsafe_get(node) >= 0 {
      depth += 1
      node = parents.unsafe_get(node)
    }
    if depth <= 0 || depth > ZSTD_HUFFMAN_MAX_BITS {
      return None
    }
    if depth > table_log {
      table_log = depth
    }
    depths_by_symbol.unsafe_set(symbols.unsafe_get(leaf), depth)
  }
  for sym in 0..<highest_symbol {
    let depth = depths_by_symbol.unsafe_get(sym)
    partial_weights.push(if depth == 0 { 0 } else { table_log + 1 - depth })
  }
  let table_result = try? ZstdHuffmanTable::from_weights(partial_weights)
  match table_result {
    Ok(table) => Some({ table, partial_weights, highest_symbol })
    Err(_) => None
  }
}

///|
fn write_direct_huffman_table_description(
  info : HuffmanLiteralTableInfo,
) -> Bytes? {
  if info.highest_symbol > 128 {
    return None
  }
  let desc_len = 1 + ((info.highest_symbol + 1) >> 1)
  let desc = FixedArray::make(desc_len, b'\x00')
  desc.unsafe_set(0, (127 + info.highest_symbol).to_byte())
  for sym in 0..<info.highest_symbol {
    let weight = info.partial_weights.unsafe_get(sym)
    let idx = 1 + (sym >> 1)
    let existing = desc.unsafe_get(idx).to_int()
    if (sym & 1) == 0 {
      desc.unsafe_set(idx, ((weight << 4) | existing).to_byte())
    } else {
      desc.unsafe_set(idx, ((existing & 0xF0) | weight).to_byte())
    }
  }
  Some(fixed_array_prefix_to_bytes(desc, desc_len))
}

///|
fn write_fse_huffman_table_description(
  info : HuffmanLiteralTableInfo,
) -> Bytes? {
  let num_weights = info.partial_weights.length()
  if num_weights <= 2 {
    return None
  }
  let weights = FixedArray::make(num_weights, 0)
  let histogram = FixedArray::make(ZSTD_HUFFMAN_MAX_BITS + 1, 0)
  let mut max_weight = 0
  let mut max_count = 0
  for i in 0..<num_weights {
    let weight = info.partial_weights.unsafe_get(i)
    weights.unsafe_set(i, weight)
    let next = histogram.unsafe_get(weight) + 1
    histogram.unsafe_set(weight, next)
    if weight > max_weight {
      max_weight = weight
    }
    if next > max_count {
      max_count = next
    }
  }
  if max_weight == 0 || max_count == num_weights || max_count == 1 {
    return None
  }
  match
    build_custom_fse_plan_with_low_prob(
      weights, num_weights, max_weight, 6, false,
    ) {
    Some(plan) => {
      let ctable = build_fse_ctable(
        plan.norm_counts,
        plan.actual_max_symbol,
        plan.table_log,
      )
      match
        write_fse_ncount(
          plan.norm_counts,
          plan.actual_max_symbol,
          plan.table_log,
        ) {
        Some(header) => {
          let payload = encode_fse_symbol_stream(weights, num_weights, ctable)
          let payload_size = header.length() + payload.length()
          if payload.length() == 0 || payload_size <= 1 || payload_size >= 128 {
            return None
          }
          let out = FixedArray::make(1 + payload_size, b'\x00')
          out.unsafe_set(0, payload_size.to_byte())
          let mut pos = 1
          for i in 0..<header.length() {
            out.unsafe_set(pos + i, header[i])
          }
          pos += header.length()
          for i in 0..<payload.length() {
            out.unsafe_set(pos + i, payload[i])
          }
          Some(fixed_array_prefix_to_bytes(out, 1 + payload_size))
        }
        None => None
      }
    }
    None => None
  }
}

///|
fn count_root_nodes(parents : FixedArray[Int], node_count : Int) -> Int {
  let mut roots = 0
  for i in 0..<node_count {
    if parents.unsafe_get(i) < 0 {
      roots += 1
    }
  }
  roots
}

///|
fn find_lowest_huffman_node(
  frequencies : FixedArray[Int],
  parents : FixedArray[Int],
  node_count : Int,
  skip : Int,
) -> Int {
  let mut best = -1
  for i in 0..<node_count {
    if i == skip || parents.unsafe_get(i) >= 0 {
      continue
    }
    if best < 0 ||
      frequencies.unsafe_get(i) < frequencies.unsafe_get(best) ||
      (frequencies.unsafe_get(i) == frequencies.unsafe_get(best) && i < best) {
      best = i
    }
  }
  best
}

///|
fn build_huffman_codebook(table : ZstdHuffmanTable) -> HuffmanCodebook {
  let codes = FixedArray::make(256, 0)
  let bits = FixedArray::make(256, 0)
  let valid = FixedArray::make(256, false)
  for i in 0..<table.entries.length() {
    let entry = table.entries.unsafe_get(i)
    let sym = ((entry >> 8) & 0xFFU).reinterpret_as_int()
    let n_bits = (entry & 0xFFU).reinterpret_as_int()
    if n_bits > 0 && !valid.unsafe_get(sym) {
      let shift = table.max_bits - n_bits
      codes.unsafe_set(sym, i >> shift)
      bits.unsafe_set(sym, n_bits)
      valid.unsafe_set(sym, true)
    }
  }
  { codes, bits, valid }
}

///|
fn codebook_can_encode_literals(
  codebook : HuffmanCodebook,
  literals : FixedArray[Byte],
  lit_start : Int,
  lit_count : Int,
) -> Bool {
  for i in 0..<lit_count {
    if !codebook.valid.unsafe_get(literals.unsafe_get(lit_start + i).to_int()) {
      return false
    }
  }
  true
}

///|
fn encode_literals_with_codebook(
  codebook : HuffmanCodebook,
  literals : FixedArray[Byte],
  lit_start : Int,
  lit_count : Int,
  dst : FixedArray[Byte],
  dst_pos : Int,
) -> Int {
  let bw = FseBitWriter::new(dst.length())
  for i = lit_count - 1; i >= 0; i = i - 1 {
    let sym = literals.unsafe_get(lit_start + i).to_int()
    bw.add_bits(codebook.codes.unsafe_get(sym), codebook.bits.unsafe_get(sym))
    bw.flush()
  }
  bw.close()
  bw.copy_to(dst, dst_pos)
}

///|
fn select_sequence_encoder(
  codes : FixedArray[Int],
  num_codes : Int,
  max_symbol : Int,
  default_decoder : SeqDecoder,
  default_norm : FixedArray[Int],
  default_accuracy : Int,
  previous : SeqDecoder?,
) -> SeqEncoderChoice {
  let first = codes.unsafe_get(0)
  let mut all_same = true
  for i in 1..<num_codes {
    if codes.unsafe_get(i) != first {
      all_same = false
      break
    }
  }
  if all_same {
    return {
      mode: 1,
      ctable: None,
      rle_symbol: Some(first),
      next_decoder: SeqDecoder::Rle(first),
      header: None,
    }
  }
  let default_ctable = build_fse_ctable(
    default_norm, max_symbol, default_accuracy,
  )
  let mut best_choice : SeqEncoderChoice = {
    mode: 0,
    ctable: Some(default_ctable),
    rle_symbol: None,
    next_decoder: default_decoder,
    header: None,
  }
  let mut best_cost_bits = estimate_fse_encode_bits(
    default_ctable, codes, num_codes,
  )
  match previous {
    Some(prev) if seq_decoder_can_encode(prev, codes, num_codes) =>
      match prev {
        SeqDecoder::Fse(table) => {
          let repeat_ctable = build_repeat_ctable(table, max_symbol)
          let repeat_cost = estimate_fse_encode_bits(
            repeat_ctable, codes, num_codes,
          )
          if repeat_cost <= best_cost_bits {
            best_cost_bits = repeat_cost
            best_choice = {
              mode: 3,
              ctable: Some(repeat_ctable),
              rle_symbol: None,
              next_decoder: prev,
              header: None,
            }
          }
        }
        SeqDecoder::Rle(sym) =>
          if num_codes == 1 || first == sym {
            best_choice = {
              mode: 3,
              ctable: None,
              rle_symbol: Some(sym),
              next_decoder: prev,
              header: None,
            }
          }
      }
    _ => ()
  }
  match
    try_build_custom_sequence_encoder(
      codes, num_codes, max_symbol, default_accuracy,
    ) {
    Some((custom_choice, custom_cost)) if custom_cost < best_cost_bits =>
      custom_choice
    _ => best_choice
  }
}

///|
fn write_sequence_choice_header(
  dst : FixedArray[Byte],
  pos_ : Int,
  choice : SeqEncoderChoice,
) -> Int {
  let mut pos = pos_
  if choice.mode == 1 {
    match choice.rle_symbol {
      Some(sym) => dst.unsafe_set(pos, sym.to_byte())
      None => dst.unsafe_set(pos, b'\x00')
    }
    pos += 1
  }
  if choice.mode == 2 {
    match choice.header {
      Some(header) => {
        for i in 0..<header.length() {
          dst.unsafe_set(pos + i, header[i])
        }
        pos += header.length()
      }
      None => ()
    }
  }
  pos - pos_
}

///|
fn try_build_custom_sequence_encoder(
  codes : FixedArray[Int],
  num_codes : Int,
  max_symbol : Int,
  max_table_log : Int,
) -> (SeqEncoderChoice, Int)? {
  match build_custom_fse_plan(codes, num_codes, max_symbol, max_table_log) {
    Some(plan) => {
      let ctable = build_fse_ctable(
        plan.norm_counts,
        plan.actual_max_symbol,
        plan.table_log,
      )
      match
        write_fse_ncount(
          plan.norm_counts,
          plan.actual_max_symbol,
          plan.table_log,
        ) {
        Some(header) => {
          let decoder = SeqDecoder::Fse(
            FseTable::build(
              plan.norm_counts,
              plan.actual_max_symbol,
              plan.table_log,
            ),
          )
          let cost = estimate_fse_encode_bits(ctable, codes, num_codes) +
            header.length() * 8
          Some(
            (
              {
                mode: 2,
                ctable: Some(ctable),
                rle_symbol: None,
                next_decoder: decoder,
                header: Some(header),
              },
              cost,
            ),
          )
        }
        None => None
      }
    }
    None => None
  }
}

///|
fn build_custom_fse_plan(
  codes : FixedArray[Int],
  num_codes : Int,
  max_symbol : Int,
  max_table_log : Int,
) -> FseNormPlan? {
  build_custom_fse_plan_with_low_prob(
    codes,
    num_codes,
    max_symbol,
    max_table_log,
    num_codes >= 2048,
  )
}

///|
fn build_custom_fse_plan_with_low_prob(
  codes : FixedArray[Int],
  num_codes : Int,
  max_symbol : Int,
  max_table_log : Int,
  use_low_prob_count : Bool,
) -> FseNormPlan? {
  if num_codes <= 1 {
    return None
  }
  let counts = FixedArray::make(max_symbol + 1, 0)
  let mut actual_max_symbol = 0
  for i in 0..<num_codes {
    let sym = codes.unsafe_get(i)
    counts.unsafe_set(sym, counts.unsafe_get(sym) + 1)
    if sym > actual_max_symbol {
      actual_max_symbol = sym
    }
  }
  let table_log = fse_optimal_table_log(
    max_table_log, num_codes, actual_max_symbol,
  )
  if table_log < FSE_MIN_TABLELOG {
    return None
  }
  let norm_counts = FixedArray::make(max_symbol + 1, 0)
  if !normalize_fse_counts(
      norm_counts, table_log, counts, num_codes, actual_max_symbol, use_low_prob_count,
    ) {
    return None
  }
  Some({ norm_counts, actual_max_symbol, table_log })
}

///|
fn fse_optimal_table_log(
  max_table_log : Int,
  src_size : Int,
  max_symbol : Int,
) -> Int {
  if src_size <= 1 {
    return FSE_MIN_TABLELOG
  }
  let mut table_log = max_table_log
  let max_bits_src = highest_bit(src_size - 1) - 3
  let min_bits_src = highest_bit(src_size)
  let min_bits_symbols = highest_bit(max_symbol) + 1
  let min_bits = if min_bits_src < min_bits_symbols {
    min_bits_src
  } else {
    min_bits_symbols
  }
  if max_bits_src > 0 && max_bits_src < table_log {
    table_log = max_bits_src
  }
  if min_bits > table_log {
    table_log = min_bits
  }
  if table_log < FSE_MIN_TABLELOG {
    table_log = FSE_MIN_TABLELOG
  }
  table_log
}

///|
fn normalize_fse_counts(
  normalized : FixedArray[Int],
  table_log : Int,
  counts : FixedArray[Int],
  total : Int,
  max_symbol : Int,
  use_low_prob_count : Bool,
) -> Bool {
  let low_prob_count = if use_low_prob_count { -1 } else { 1 }
  let scale = 62 - table_log
  let step = (1UL << 62) / int_to_uint64(total)
  let vstep = 1UL << (scale - 20)
  let rtb_table : FixedArray[UInt64] = [
    0UL, 473195UL, 504333UL, 520860UL, 550000UL, 700000UL, 750000UL, 830000UL,
  ]
  let mut still_to_distribute = 1 << table_log
  let low_threshold = total >> table_log
  let mut largest = 0
  let mut largest_p = 0
  for sym in 0..<=max_symbol {
    let count = counts.unsafe_get(sym)
    if count == 0 {
      normalized.unsafe_set(sym, 0)
      continue
    }
    if count <= low_threshold {
      normalized.unsafe_set(sym, low_prob_count)
      still_to_distribute -= 1
      continue
    }
    let mut proba = ((int_to_uint64(count) * step) >> scale).to_int()
    if proba < 8 {
      let rest_to_beat = vstep * rtb_table.unsafe_get(proba)
      let scaled = int_to_uint64(count) * step
      if scaled - (int_to_uint64(proba) << scale) > rest_to_beat {
        proba += 1
      }
    }
    if proba > largest_p {
      largest_p = proba
      largest = sym
    }
    normalized.unsafe_set(sym, proba)
    still_to_distribute -= proba
  }
  if still_to_distribute < 0 &&
    -still_to_distribute >= normalized.unsafe_get(largest) / 2 {
    return normalize_fse_counts_m2(
      normalized, table_log, counts, total, max_symbol, low_prob_count,
    )
  }
  normalized.unsafe_set(
    largest,
    normalized.unsafe_get(largest) + still_to_distribute,
  )
  let mut sum = 0
  for sym in 0..<=max_symbol {
    sum += int_abs(normalized.unsafe_get(sym))
  }
  sum == 1 << table_log
}

///|
fn normalize_fse_counts_m2(
  normalized : FixedArray[Int],
  table_log : Int,
  counts : FixedArray[Int],
  total_ : Int,
  max_symbol : Int,
  low_prob_count : Int,
) -> Bool {
  let not_assigned = -2
  let mut distributed = 0
  let mut total = total_
  let low_threshold = total_ >> table_log
  let mut low_one = (total_ * 3) >> (table_log + 1)
  for sym in 0..<=max_symbol {
    let count = counts.unsafe_get(sym)
    if count == 0 {
      normalized.unsafe_set(sym, 0)
    } else if count <= low_threshold {
      normalized.unsafe_set(sym, low_prob_count)
      distributed += 1
      total -= count
    } else if count <= low_one {
      normalized.unsafe_set(sym, 1)
      distributed += 1
      total -= count
    } else {
      normalized.unsafe_set(sym, not_assigned)
    }
  }
  let table_size = 1 << table_log
  let mut to_distribute = table_size - distributed
  if to_distribute == 0 {
    return true
  }
  if total > 0 && total / to_distribute > low_one {
    low_one = total * 3 / (to_distribute * 2)
    for sym in 0..<=max_symbol {
      if normalized.unsafe_get(sym) == not_assigned &&
        counts.unsafe_get(sym) <= low_one {
        normalized.unsafe_set(sym, 1)
        distributed += 1
        total -= counts.unsafe_get(sym)
      }
    }
    to_distribute = table_size - distributed
  }
  if distributed == max_symbol + 1 {
    let mut max_count = 0
    let mut max_idx = 0
    for sym in 0..<=max_symbol {
      if counts.unsafe_get(sym) > max_count {
        max_count = counts.unsafe_get(sym)
        max_idx = sym
      }
    }
    normalized.unsafe_set(
      max_idx,
      normalized.unsafe_get(max_idx) + to_distribute,
    )
    return true
  }
  if total == 0 {
    let mut sym = 0
    while to_distribute > 0 {
      if normalized.unsafe_get(sym) > 0 {
        normalized.unsafe_set(sym, normalized.unsafe_get(sym) + 1)
        to_distribute -= 1
      }
      sym = if sym == max_symbol { 0 } else { sym + 1 }
    }
    return true
  }
  let vstep_log = 62 - table_log
  let mid = (1UL << (vstep_log - 1)) - 1UL
  let rstep = ((1UL << vstep_log) * int_to_uint64(to_distribute) + mid) /
    int_to_uint64(total)
  let mut tmp_total = mid
  for sym in 0..<=max_symbol {
    if normalized.unsafe_get(sym) == not_assigned {
      let end = tmp_total + int_to_uint64(counts.unsafe_get(sym)) * rstep
      let start_bucket = (tmp_total >> vstep_log).to_int()
      let end_bucket = (end >> vstep_log).to_int()
      let weight = end_bucket - start_bucket
      if weight < 1 {
        return false
      }
      normalized.unsafe_set(sym, weight)
      tmp_total = end
    }
  }
  let mut sum = 0
  for sym in 0..<=max_symbol {
    sum += int_abs(normalized.unsafe_get(sym))
  }
  sum == table_size
}

///|
fn write_fse_ncount(
  normalized : FixedArray[Int],
  max_symbol : Int,
  table_log : Int,
) -> Bytes? {
  let out = @blit.Buffer::new(size_hint=(max_symbol + 1) * 2 + 8)
  let mut bit_stream = int_to_uint64(table_log - FSE_MIN_TABLELOG)
  let mut bit_count = 4
  let table_size = 1 << table_log
  let mut remaining = table_size + 1
  let mut threshold = table_size
  let mut nb_bits = table_log + 1
  let mut symbol = 0
  let mut previous_is_zero = false
  while symbol <= max_symbol && remaining > 1 {
    if previous_is_zero {
      let mut start = symbol
      while symbol <= max_symbol && normalized.unsafe_get(symbol) == 0 {
        symbol += 1
      }
      if symbol > max_symbol {
        break
      }
      while symbol >= start + 24 {
        start += 24
        bit_stream += 0xFFFFUL << bit_count
        out.write_byte((bit_stream & 0xFFUL).to_uint().to_byte())
        out.write_byte(((bit_stream >> 8) & 0xFFUL).to_uint().to_byte())
        bit_stream = bit_stream >> 16
      }
      while symbol >= start + 3 {
        start += 3
        bit_stream += 3UL << bit_count
        bit_count += 2
      }
      bit_stream += int_to_uint64(symbol - start) << bit_count
      bit_count += 2
      while bit_count > 16 {
        out.write_byte((bit_stream & 0xFFUL).to_uint().to_byte())
        out.write_byte(((bit_stream >> 8) & 0xFFUL).to_uint().to_byte())
        bit_stream = bit_stream >> 16
        bit_count -= 16
      }
    }
    let count0 = normalized.unsafe_get(symbol)
    symbol += 1
    let max = 2 * threshold - 1 - remaining
    remaining -= int_abs(count0)
    let mut count = count0 + 1
    if count >= threshold {
      count += max
    }
    bit_stream += int_to_uint64(count) << bit_count
    bit_count += nb_bits
    if count < max {
      bit_count -= 1
    }
    previous_is_zero = count == 1
    if remaining < 1 {
      return None
    }
    while remaining < threshold {
      nb_bits -= 1
      threshold = threshold >> 1
    }
    while bit_count > 16 {
      out.write_byte((bit_stream & 0xFFUL).to_uint().to_byte())
      out.write_byte(((bit_stream >> 8) & 0xFFUL).to_uint().to_byte())
      bit_stream = bit_stream >> 16
      bit_count -= 16
    }
  }
  if remaining != 1 {
    return None
  }
  out.write_byte((bit_stream & 0xFFUL).to_uint().to_byte())
  out.write_byte(((bit_stream >> 8) & 0xFFUL).to_uint().to_byte())
  let bytes = out.to_bytes()
  let used = bytes.length() - 2 + ((bit_count + 7) >> 3)
  Some(Bytes::makei(used, fn(i) { bytes[i] }))
}

///|
fn estimate_fse_encode_bits(
  ct : FseCTable,
  codes : FixedArray[Int],
  num_codes : Int,
) -> Int {
  if num_codes == 0 {
    return 0
  }
  let mut bits = ct.table_log
  let mut state = fse_init_state(ct, codes.unsafe_get(num_codes - 1))
  for i = num_codes - 2; i >= 0; i = i - 1 {
    let symbol = codes.unsafe_get(i)
    let stt = ct.symbol_tt.unsafe_get(symbol)
    let nb_bits_out = (state + stt.delta_nb_bits) >> 16
    bits += nb_bits_out
    state = ct.state_table.unsafe_get(
      (state >> nb_bits_out) + stt.delta_find_state,
    )
  }
  bits
}

///|
fn encode_fse_symbol_stream(
  codes : FixedArray[Int],
  num_codes : Int,
  ct : FseCTable,
) -> Bytes {
  if num_codes <= 2 {
    return b""
  }
  let temp = FixedArray::make(num_codes * 2 + 32, b'\x00')
  let bw = FseBitWriter::new(temp.length())
  let mut ip = num_codes
  let mut state1 = 0
  let mut state2 = 0
  if (num_codes & 1) == 1 {
    ip -= 1
    state1 = fse_init_state(ct, codes.unsafe_get(ip))
    ip -= 1
    state2 = fse_init_state(ct, codes.unsafe_get(ip))
    ip -= 1
    state1 = fse_encode_symbol(ct, bw, state1, codes.unsafe_get(ip))
    bw.flush()
  } else {
    ip -= 1
    state2 = fse_init_state(ct, codes.unsafe_get(ip))
    ip -= 1
    state1 = fse_init_state(ct, codes.unsafe_get(ip))
  }
  if ((num_codes - 2) & 2) != 0 {
    ip -= 1
    state2 = fse_encode_symbol(ct, bw, state2, codes.unsafe_get(ip))
    ip -= 1
    state1 = fse_encode_symbol(ct, bw, state1, codes.unsafe_get(ip))
    bw.flush()
  }
  while ip > 0 {
    ip -= 1
    state2 = fse_encode_symbol(ct, bw, state2, codes.unsafe_get(ip))
    ip -= 1
    state1 = fse_encode_symbol(ct, bw, state1, codes.unsafe_get(ip))
    ip -= 1
    state2 = fse_encode_symbol(ct, bw, state2, codes.unsafe_get(ip))
    ip -= 1
    state1 = fse_encode_symbol(ct, bw, state1, codes.unsafe_get(ip))
    bw.flush()
  }
  fse_flush_state(bw, state2, ct.table_log)
  fse_flush_state(bw, state1, ct.table_log)
  bw.close()
  let size = bw.copy_to(temp, 0)
  fixed_array_prefix_to_bytes(temp, size)
}

///|
fn int_abs(n : Int) -> Int {
  if n < 0 {
    -n
  } else {
    n
  }
}

///|
fn int_to_uint64(n : Int) -> UInt64 {
  n.reinterpret_as_uint().to_uint64()
}

///|
fn seq_decoder_can_encode(
  decoder : SeqDecoder,
  codes : FixedArray[Int],
  num_codes : Int,
) -> Bool {
  match decoder {
    SeqDecoder::Rle(sym) => {
      for i in 0..<num_codes {
        if codes.unsafe_get(i) != sym {
          return false
        }
      }
      true
    }
    SeqDecoder::Fse(table) => {
      let supported = FixedArray::make(256, false)
      for i in 0..<table.symbols.length() {
        supported.unsafe_set(table.symbols.unsafe_get(i).to_int(), true)
      }
      for i in 0..<num_codes {
        if !supported.unsafe_get(codes.unsafe_get(i)) {
          return false
        }
      }
      true
    }
  }
}

///|
fn build_repeat_ctable(table : FseTable, max_symbol : Int) -> FseCTable {
  let counts = FixedArray::make(max_symbol + 1, 0)
  for i in 0..<table.symbols.length() {
    let sym = table.symbols.unsafe_get(i).to_int()
    counts.unsafe_set(sym, counts.unsafe_get(sym) + 1)
  }
  let symbol_tt = FixedArray::make(max_symbol + 1, {
    delta_nb_bits: 0,
    delta_find_state: 0,
  })
  let mut total = 0
  for sym in 0..<=max_symbol {
    let count = counts.unsafe_get(sym)
    if count == 0 {
      continue
    }
    if count == 1 {
      symbol_tt.unsafe_set(sym, {
        delta_nb_bits: (table._accuracy_log << 16) - (1 << table._accuracy_log),
        delta_find_state: total - 1,
      })
      total += 1
    } else {
      let max_bits_out = table._accuracy_log - (highest_bit(count - 1) - 1)
      let min_state_plus = count << max_bits_out
      symbol_tt.unsafe_set(sym, {
        delta_nb_bits: (max_bits_out << 16) - min_state_plus,
        delta_find_state: total - count,
      })
      total += count
    }
  }
  let state_table = FixedArray::make(table.symbols.length(), 0)
  let cum = FixedArray::make(max_symbol + 1, 0)
  let mut c = 0
  for sym in 0..<=max_symbol {
    cum.unsafe_set(sym, c)
    c += counts.unsafe_get(sym)
  }
  let seen = FixedArray::make(max_symbol + 1, 0)
  for i in 0..<table.symbols.length() {
    let sym = table.symbols.unsafe_get(i).to_int()
    let pos = cum.unsafe_get(sym) + seen.unsafe_get(sym)
    state_table.unsafe_set(pos, table.symbols.length() + i)
    seen.unsafe_set(sym, seen.unsafe_get(sym) + 1)
  }
  { state_table, symbol_tt, table_log: table._accuracy_log }
}

///|
fn encode_sequences(
  sequences : Array[ZstdSequence],
  ll_codes : FixedArray[Int],
  of_codes : FixedArray[Int],
  ml_codes : FixedArray[Int],
  ll_ct : FseCTable?,
  ll_rle : Int?,
  of_ct : FseCTable?,
  of_rle : Int?,
  ml_ct : FseCTable?,
  ml_rle : Int?,
  dst : FixedArray[Byte],
  dst_pos : Int,
) -> Int {
  let num_seq = sequences.length()
  if num_seq == 0 {
    return 0
  }
  let bw = FseBitWriter::new(num_seq * 20 + 64)
  let last = sequences.unsafe_get(num_seq - 1)
  let ll_code_last = ll_codes.unsafe_get(num_seq - 1)
  let of_code_last = of_codes.unsafe_get(num_seq - 1)
  let ml_code_last = ml_codes.unsafe_get(num_seq - 1)
  let (_ll_code_last_check, ll_xb_last, ll_xv_last) = get_ll_code(last.lit_len)
  let (_of_code_last_check, _of_xb_last, of_xv_last) = get_offset_code(
    last.offset,
  )
  let (_ml_code_last_check, ml_xb_last, ml_xv_last) = get_ml_code(
    last.match_len,
  )
  let mut ll_state = match ll_ct {
    Some(ct) => fse_init_state(ct, ll_code_last)
    None => 0
  }
  let mut of_state = match of_ct {
    Some(ct) => fse_init_state(ct, of_code_last)
    None => 0
  }
  let mut ml_state = match ml_ct {
    Some(ct) => fse_init_state(ct, ml_code_last)
    None => 0
  }
  ignore(ll_rle)
  ignore(of_rle)
  ignore(ml_rle)
  bw.add_bits(ll_xv_last, ll_xb_last)
  bw.flush()
  bw.add_bits(ml_xv_last, ml_xb_last)
  bw.add_bits(of_xv_last, of_code_last)
  bw.flush()
  for n = num_seq - 2; n >= 0; n = n - 1 {
    let seq = sequences.unsafe_get(n)
    let of_code = of_codes.unsafe_get(n)
    let ml_code = ml_codes.unsafe_get(n)
    let ll_code = ll_codes.unsafe_get(n)
    let (_of_code_check, _of_xb, of_xv) = get_offset_code(seq.offset)
    let (_ml_code_check, ml_xb, ml_xv) = get_ml_code(seq.match_len)
    let (_ll_code_check, ll_xb, ll_xv) = get_ll_code(seq.lit_len)
    match of_ct {
      Some(ct) => of_state = fse_encode_symbol(ct, bw, of_state, of_code)
      None => ()
    }
    match ml_ct {
      Some(ct) => ml_state = fse_encode_symbol(ct, bw, ml_state, ml_code)
      None => ()
    }
    bw.flush()
    match ll_ct {
      Some(ct) => ll_state = fse_encode_symbol(ct, bw, ll_state, ll_code)
      None => ()
    }
    bw.flush()
    bw.add_bits(ll_xv, ll_xb)
    bw.flush()
    bw.add_bits(ml_xv, ml_xb)
    bw.add_bits(of_xv, of_code)
    bw.flush()
  }
  match ml_ct {
    Some(ct) => fse_flush_state(bw, ml_state, ct.table_log)
    None => ()
  }
  match of_ct {
    Some(ct) => fse_flush_state(bw, of_state, ct.table_log)
    None => ()
  }
  match ll_ct {
    Some(ct) => fse_flush_state(bw, ll_state, ct.table_log)
    None => ()
  }
  bw.close()
  bw.copy_to(dst, dst_pos)
}
