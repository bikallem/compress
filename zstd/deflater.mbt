///|
const ZSTD_STREAM_WINDOW : Int = MAX_WINDOW_SIZE

///|
priv struct EncoderState {
  level : CompressionLevel
  dict : ZstdDictionary
  mut input_buf : @blit.Buffer
  mut input_pos : Int
  mut header_emitted : Bool
  mut finished : Bool
  mut history : @blit.Buffer
  rep : Array[Int]
  mut prev_lit_table : ZstdHuffmanTable?
  mut prev_seq_tables : SeqTables?
  checksum : @checksum.XXH64
}

///|
struct Deflater(EncoderState)

///|
pub fn Deflater::new(
  level? : CompressionLevel = Default,
  dict? : Bytes = Bytes::default(),
) -> Deflater raise ZstdError {
  let parsed_dict = parse_dictionary_for_encoder(dict)
  Deflater({
    level,
    dict: parsed_dict,
    input_buf: @blit.Buffer::new(),
    input_pos: 0,
    header_emitted: false,
    finished: false,
    history: @blit.Buffer::new(),
    rep: copy_rep_offsets(parsed_dict.rep),
    prev_lit_table: parsed_dict.lit_table,
    prev_seq_tables: parsed_dict.seq_tables,
    checksum: @checksum.XXH64::new(),
  })
}

///|
pub fn Deflater::encode(self : Deflater, data : BytesView?) -> Encode {
  let s = self.0
  if s.finished {
    return End
  }
  match data {
    Some(chunk) => {
      if chunk.length() == 0 {
        return Ok
      }
      s.input_buf.write_bytesview(chunk)
      s.checksum.update(chunk[:])
      match pump_encoder(s, false) {
        Some(out) => Data(out[:])
        None => Ok
      }
    }
    None =>
      match pump_encoder(s, true) {
        Some(out) => {
          s.finished = true
          Data(out[:])
        }
        None => {
          s.finished = true
          End
        }
      }
  }
}

///|
fn pump_encoder(s : EncoderState, finish : Bool) -> Bytes? {
  let input = s.input_buf.to_bytes()
  let available = input.length() - s.input_pos
  if !finish && available < MAX_BLOCK_SIZE {
    return None
  }
  let out = @blit.Buffer::new()
  if !s.header_emitted {
    write_zstd_stream_header(out, ZSTD_STREAM_WINDOW, s.dict.dict_id)
    s.header_emitted = true
  }
  if finish {
    if available == 0 {
      write_block_header_buffer(out, true, BLOCK_TYPE_RAW, 0)
    } else {
      let mut remaining = available
      while remaining > MAX_BLOCK_SIZE {
        let chunk = bytes_slice(input, s.input_pos, MAX_BLOCK_SIZE)
        let (next_lit, next_seq) = write_encoded_block(
          out,
          chunk,
          encoder_prefix(s),
          s.rep,
          s.prev_lit_table,
          s.prev_seq_tables,
          s.level,
          false,
        )
        s.prev_lit_table = next_lit
        s.prev_seq_tables = next_seq
        append_encode_history(s, chunk)
        s.input_pos += MAX_BLOCK_SIZE
        remaining -= MAX_BLOCK_SIZE
      }
      let chunk = bytes_slice(input, s.input_pos, remaining)
      let (next_lit, next_seq) = write_encoded_block(
        out,
        chunk,
        encoder_prefix(s),
        s.rep,
        s.prev_lit_table,
        s.prev_seq_tables,
        s.level,
        true,
      )
      s.prev_lit_table = next_lit
      s.prev_seq_tables = next_seq
      append_encode_history(s, chunk)
      s.input_pos += remaining
    }
    let cs32 = s.checksum.checksum64().to_uint()
    write_stream_le_value(out, cs32, 4)
    compact_encoder_input(s)
    Some(out.to_bytes())
  } else {
    let mut remaining = available
    while remaining >= MAX_BLOCK_SIZE {
      let chunk = bytes_slice(input, s.input_pos, MAX_BLOCK_SIZE)
      let (next_lit, next_seq) = write_encoded_block(
        out,
        chunk,
        encoder_prefix(s),
        s.rep,
        s.prev_lit_table,
        s.prev_seq_tables,
        s.level,
        false,
      )
      s.prev_lit_table = next_lit
      s.prev_seq_tables = next_seq
      append_encode_history(s, chunk)
      s.input_pos += MAX_BLOCK_SIZE
      remaining -= MAX_BLOCK_SIZE
    }
    compact_encoder_input(s)
    if out.length() > 0 {
      Some(out.to_bytes())
    } else {
      None
    }
  }
}

///|
fn encoder_prefix(s : EncoderState) -> Bytes {
  let history = s.history.to_bytes()
  let dict = s.dict.content
  let total = dict.length() + history.length()
  if total == 0 {
    return b""
  }
  let keep = if total > ZSTD_STREAM_WINDOW { ZSTD_STREAM_WINDOW } else { total }
  let skip = total - keep
  let out = @blit.Buffer::new(size_hint=keep)
  if skip < dict.length() {
    out.write_bytesview(dict[skip:])
    out.write_bytes(history)
  } else {
    let hist_skip = skip - dict.length()
    if hist_skip < history.length() {
      out.write_bytesview(history[hist_skip:])
    }
  }
  out.to_bytes()
}

///|
fn append_encode_history(s : EncoderState, chunk : Bytes) -> Unit {
  if chunk.length() == 0 {
    return
  }
  let history = s.history.to_bytes()
  let total = history.length() + chunk.length()
  let keep = if total > ZSTD_STREAM_WINDOW { ZSTD_STREAM_WINDOW } else { total }
  let skip = total - keep
  let next = @blit.Buffer::new(size_hint=keep)
  if skip < history.length() {
    next.write_bytesview(history[skip:])
    next.write_bytes(chunk)
  } else {
    let chunk_skip = skip - history.length()
    next.write_bytesview(chunk[chunk_skip:])
  }
  s.history = next
}

///|
fn compact_encoder_input(s : EncoderState) -> Unit {
  let input = s.input_buf.to_bytes()
  if s.input_pos == 0 {
    return
  }
  let remaining = input.length() - s.input_pos
  let next = @blit.Buffer::new(size_hint=remaining)
  if remaining > 0 {
    next.write_bytesview(input[s.input_pos:])
  }
  s.input_buf = next
  s.input_pos = 0
}

///|
fn bytes_slice(data : Bytes, start : Int, length : Int) -> Bytes {
  Bytes::makei(length, fn(i) { data[start + i] })
}

///|
fn write_block_header_buffer(
  dst : @blit.Buffer,
  is_last : Bool,
  block_type : Int,
  block_size : Int,
) -> Unit {
  let last_flag = if is_last { 1 } else { 0 }
  let block_header = last_flag | (block_type << 1) | (block_size << 3)
  dst.write_byte((block_header & 0xFF).to_byte())
  dst.write_byte(((block_header >> 8) & 0xFF).to_byte())
  dst.write_byte(((block_header >> 16) & 0xFF).to_byte())
}

///|
fn write_encoded_block(
  dst : @blit.Buffer,
  chunk : Bytes,
  prefix : Bytes,
  rep : Array[Int],
  prev_lit_table : ZstdHuffmanTable?,
  prev_seq_tables : SeqTables?,
  level : CompressionLevel,
  is_last : Bool,
) -> (ZstdHuffmanTable?, SeqTables?) {
  let chunk_view = chunk[:]
  if chunk.length() == 0 {
    write_block_header_buffer(dst, is_last, BLOCK_TYPE_RAW, 0)
    return (prev_lit_table, prev_seq_tables)
  }
  if is_all_same(chunk_view) {
    write_block_header_buffer(dst, is_last, BLOCK_TYPE_RLE, chunk.length())
    dst.write_byte(chunk[0])
    return (prev_lit_table, prev_seq_tables)
  }
  let rep_next = copy_rep_offsets(rep)
  let (sequences, literals, lit_count) = find_sequences_with_prefix(
    chunk_view,
    prefix[:],
    rep_next,
    level,
  )
  let comp_buf = FixedArray::make(chunk.length() * 2 + 256, b'\x00')
  let (comp_size, next_lit, next_seq) = if sequences.length() > 0 {
    compress_block_from_sequences(
      sequences, literals, 0, lit_count, comp_buf, prev_lit_table, prev_seq_tables,
    )
  } else {
    let chunk_literals = fixed_array_from_bytesview(chunk_view)
    compress_literal_only_block(
      chunk_literals,
      0,
      chunk.length(),
      comp_buf,
      prev_lit_table,
      prev_seq_tables,
    )
  }
  if comp_size > 0 && comp_size < chunk.length() {
    write_block_header_buffer(dst, is_last, BLOCK_TYPE_COMPRESSED, comp_size)
    for i in 0..<comp_size {
      dst.write_byte(comp_buf.unsafe_get(i))
    }
    if sequences.length() > 0 {
      rep.unsafe_set(0, rep_next.unsafe_get(0))
      rep.unsafe_set(1, rep_next.unsafe_get(1))
      rep.unsafe_set(2, rep_next.unsafe_get(2))
    }
    return (next_lit, next_seq)
  }
  write_block_header_buffer(dst, is_last, BLOCK_TYPE_RAW, chunk.length())
  dst.write_bytes(chunk)
  (prev_lit_table, prev_seq_tables)
}
