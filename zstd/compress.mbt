///|
/// Compresses data using the Zstandard format.
/// Uses LZ77 match finding and zstd compressed blocks with predefined FSE tables.
pub fn compress(
  data : Bytes,
  level? : CompressionLevel = Default,
  dict? : Bytes = Bytes::default(),
) -> Bytes {
  let parsed_dict = parse_dictionary_for_encoder(dict)
  let src = data[:]
  let src_len = data.length()
  let max_out = 18 + src_len + (src_len / MAX_BLOCK_SIZE + 1) * 6 + 4
  let out = FixedArray::make(max_out, b'\x00')
  let mut pos = 0
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
  } else if zstd_is_fast_mode(level) {
    let mut src_pos = 0
    while src_pos < src_len {
      let block_end = if src_pos + MAX_BLOCK_SIZE < src_len {
        src_pos + MAX_BLOCK_SIZE
      } else {
        src_len
      }
      let block_len = block_end - src_pos
      let is_last = block_end == src_len
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
      src_pos = block_end
    }
  } else {
    let (sequences, literals, lit_count) = find_sequences_with_prefix(
      src,
      parsed_dict.content[:],
      parsed_dict.rep,
      level,
    )
    if sequences.length() == 0 {
      // No sequences found, emit as raw blocks
      let mut src_pos = 0
      while src_pos < src_len {
        let block_end = if src_pos + MAX_BLOCK_SIZE < src_len {
          src_pos + MAX_BLOCK_SIZE
        } else {
          src_len
        }
        let block_len = block_end - src_pos
        let is_last = block_end == src_len
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
        src_pos = block_end
      }
    } else {
      // Split sequences into blocks of MAX_BLOCK_SIZE decoded bytes.
      // First, split any sequence whose decoded size exceeds MAX_BLOCK_SIZE.
      let split_seqs : Array[ZstdSequence] = []
      for i in 0..<sequences.length() {
        let seq = sequences.unsafe_get(i)
        let seq_decoded = seq.lit_len + seq.match_len
        if seq_decoded <= MAX_BLOCK_SIZE {
          split_seqs.push(seq)
        } else {
          // Need to split this sequence.
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
            let offset = if first {
              seq.offset
            } else {
              // Continuation: emit as new offset to avoid lit_len=0 repeat offset ambiguity
              actual_off + 3
            }
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
        // Collect sequences for this block (up to MAX_BLOCK_SIZE decoded bytes)
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
        // Check if there are trailing literals (only for the last block)
        let mut trailing_lit_count = 0
        if seq_idx >= num_seq {
          // Last block gets trailing literals
          trailing_lit_count = lit_count - lit_offset
        }
        let total_block_lits = block_lit_count + trailing_lit_count
        let block_content_size = block_decoded + trailing_lit_count
        decoded_total += block_content_size
        let is_last = seq_idx >= num_seq
        // Encode this block
        let comp_buf = FixedArray::make(block_content_size + 256, b'\x00')
        let comp_size = compress_block_from_sequences(
          block_seqs, literals, block_lit_start, total_block_lits, comp_buf,
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
        } else {
          // Fall back to raw block - need the original source bytes
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
const ZSTD_MIN_MATCH : Int = 4

///|
priv struct ZstdSearchConfig {
  lazy_steps : Int
}

///|
fn zstd_search_config(level : CompressionLevel) -> ZstdSearchConfig {
  match level {
    Fast => { lazy_steps: 0 }
    Default => { lazy_steps: 1 }
    Best => { lazy_steps: 2 }
    Level(n) =>
      if n <= 1 {
        { lazy_steps: 0 }
      } else if n >= 8 {
        { lazy_steps: 2 }
      } else {
        { lazy_steps: 1 }
      }
  }
}

///|
fn zstd_is_fast_mode(level : CompressionLevel) -> Bool {
  match level {
    Fast => true
    Level(n) => n <= 1
    Default | Best => false
  }
}

///|
fn zstd_hash(data : BytesView, pos : Int) -> Int {
  let u = data.unsafe_get(pos).to_int() |
    (data.unsafe_get(pos + 1).to_int() << 8) |
    (data.unsafe_get(pos + 2).to_int() << 16) |
    (data.unsafe_get(pos + 3).to_int() << 24)
  let h = u.reinterpret_as_uint() * 0x9E3779B1_U
  (h >> (32 - ZSTD_HASH_BITS)).reinterpret_as_int()
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
  let hash_table = FixedArray::make(ZSTD_HASH_SIZE, -1)
  let rep = copy_rep_offsets(rep_init)
  let mut ip = base
  let mut anchor = base
  let mf_limit = combined.length() - ZSTD_MIN_MATCH
  if base >= ZSTD_MIN_MATCH {
    for i in 0..<(base - ZSTD_MIN_MATCH + 1) {
      hash_table.unsafe_set(zstd_hash(src, i), i)
    }
  }
  while ip < mf_limit {
    let hash = zstd_hash(src, ip)
    let ref_pos = hash_table.unsafe_get(hash)
    hash_table.unsafe_set(hash, ip)
    let mut match_ip = ip
    let mut best = find_best_match(
      src,
      match_ip,
      combined.length(),
      ref_pos,
      rep,
    )
    let mut lazy_steps = config.lazy_steps
    while lazy_steps > 0 &&
          best.length >= ZSTD_MIN_MATCH &&
          best.length < 32 &&
          match_ip + 1 < mf_limit {
      let next_ip = match_ip + 1
      let next_hash = zstd_hash(src, next_ip)
      let next_ref = hash_table.unsafe_get(next_hash)
      hash_table.unsafe_set(next_hash, next_ip)
      let next_best = find_best_match(
        src,
        next_ip,
        combined.length(),
        next_ref,
        rep,
      )
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
        hash_table.unsafe_set(h, j)
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
  ref_pos : Int,
  rep : Array[Int],
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
      }
    }
  }
  if ref_pos >= 0 &&
    src.unsafe_get(ref_pos) == src.unsafe_get(ip) &&
    src.unsafe_get(ref_pos + 1) == src.unsafe_get(ip + 1) &&
    src.unsafe_get(ref_pos + 2) == src.unsafe_get(ip + 2) &&
    src.unsafe_get(ref_pos + 3) == src.unsafe_get(ip + 3) {
    let mut match_len = ZSTD_MIN_MATCH
    while ip + match_len < src_end &&
          src.unsafe_get(ref_pos + match_len) == src.unsafe_get(ip + match_len) {
      match_len += 1
    }
    let hash_offset = ip - ref_pos
    if match_len > best.length + 1 || best.rep_idx < 0 {
      if match_len > best.length || best.rep_idx < 0 {
        best = { length: match_len, offset: hash_offset, rep_idx: -1 }
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
  { state_table, symbol_tt }
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
/// Encode a block from pre-computed sequences and literals.
fn compress_block_from_sequences(
  sequences : Array[ZstdSequence],
  literals : FixedArray[Byte],
  lit_start : Int,
  lit_count : Int,
  dst : FixedArray[Byte],
) -> Int {
  if sequences.length() == 0 {
    return 0
  }
  let mut pos = 0
  // Write literals section header (raw literals, type=0)
  if lit_count < 32 {
    dst.unsafe_set(pos, ((lit_count << 3) | 0).to_byte())
    pos += 1
  } else if lit_count < 4096 {
    let header = (lit_count << 4) | (1 << 2) | 0
    dst.unsafe_set(pos, (header & 0xFF).to_byte())
    dst.unsafe_set(pos + 1, ((header >> 8) & 0xFF).to_byte())
    pos += 2
  } else {
    let header = (lit_count << 4) | (3 << 2) | 0
    dst.unsafe_set(pos, (header & 0xFF).to_byte())
    dst.unsafe_set(pos + 1, ((header >> 8) & 0xFF).to_byte())
    dst.unsafe_set(pos + 2, ((header >> 16) & 0xFF).to_byte())
    pos += 3
  }
  for i in 0..<lit_count {
    dst.unsafe_set(pos + i, literals.unsafe_get(lit_start + i))
  }
  pos += lit_count
  // Write sequences section header
  let num_seq = sequences.length()
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
  // Compression modes: all predefined (0)
  dst.unsafe_set(pos, b'\x00')
  pos += 1
  // Encode sequences
  let stream_size = encode_sequences(sequences, dst, pos)
  if stream_size == 0 {
    return 0
  }
  pos += stream_size
  pos
}

///|
/// Encode sequences into a backward bitstream using predefined FSE CTables.
/// Follows the reference ZSTD_encodeSequences_body algorithm exactly.
fn encode_sequences(
  sequences : Array[ZstdSequence],
  dst : FixedArray[Byte],
  dst_pos : Int,
) -> Int {
  let num_seq = sequences.length()
  if num_seq == 0 {
    return 0
  }
  let ll_ct = build_fse_ctable(ll_default_norm, 35, LL_DEFAULT_ACCURACY)
  let of_ct = build_fse_ctable(of_default_norm, 28, OF_DEFAULT_ACCURACY)
  let ml_ct = build_fse_ctable(ml_default_norm, 52, ML_DEFAULT_ACCURACY)
  let bw = FseBitWriter::new(num_seq * 20 + 64)
  // Get codes for the last sequence
  let last = sequences.unsafe_get(num_seq - 1)
  let (ll_code_last, ll_xb_last, ll_xv_last) = get_ll_code(last.lit_len)
  let (of_code_last, _of_xb_last, of_xv_last) = get_offset_code(last.offset)
  let (ml_code_last, ml_xb_last, ml_xv_last) = get_ml_code(last.match_len)
  // Initialize FSE states with the last sequence's symbols
  let mut ll_state = fse_init_state(ll_ct, ll_code_last)
  let mut of_state = fse_init_state(of_ct, of_code_last)
  let mut ml_state = fse_init_state(ml_ct, ml_code_last)
  // Write extra bits for the last sequence (written first in forward buffer,
  // read last by decoder for the last sequence)
  bw.add_bits(ll_xv_last, ll_xb_last)
  bw.flush()
  bw.add_bits(ml_xv_last, ml_xb_last)
  bw.add_bits(of_xv_last, of_code_last) // OF extra bits count = of_code
  bw.flush()
  // Process remaining sequences from N-2 down to 0
  // Reference order per sequence:
  //   1. FSE_encodeSymbol(OF)  -- writes OF state update bits
  //   2. FSE_encodeSymbol(ML)  -- writes ML state update bits
  //   3. FSE_encodeSymbol(LL)  -- writes LL state update bits
  //   4. BIT_addBits(LL extra)
  //   5. BIT_addBits(ML extra)
  //   6. BIT_addBits(OF extra)
  for n = num_seq - 2; n >= 0; n = n - 1 {
    let seq = sequences.unsafe_get(n)
    let (of_code, _of_xb, of_xv) = get_offset_code(seq.offset)
    let (ml_code, ml_xb, ml_xv) = get_ml_code(seq.match_len)
    let (ll_code, ll_xb, ll_xv) = get_ll_code(seq.lit_len)
    // FSE encode symbols (outputs state bits, transitions state)
    of_state = fse_encode_symbol(of_ct, bw, of_state, of_code)
    ml_state = fse_encode_symbol(ml_ct, bw, ml_state, ml_code)
    bw.flush()
    ll_state = fse_encode_symbol(ll_ct, bw, ll_state, ll_code)
    bw.flush()
    // Extra bits
    bw.add_bits(ll_xv, ll_xb)
    bw.flush()
    bw.add_bits(ml_xv, ml_xb)
    bw.add_bits(of_xv, of_code) // OF extra bits count = of_code
    bw.flush()
  }
  // Flush final states (reverse of decoder init order: ML, OF, LL)
  fse_flush_state(bw, ml_state, ML_DEFAULT_ACCURACY)
  fse_flush_state(bw, of_state, OF_DEFAULT_ACCURACY)
  fse_flush_state(bw, ll_state, LL_DEFAULT_ACCURACY)
  // Close and copy (no reversal needed - backward stream is stored forward)
  bw.close()
  bw.copy_to(dst, dst_pos)
}
