///|
priv enum SeqDecoder {
  Fse(FseTable)
  Rle(Int)
}

///|
priv struct SeqTables {
  ll : SeqDecoder
  of : SeqDecoder
  ml : SeqDecoder
}

///|
/// Decompresses Zstandard-encoded data.
pub fn decompress(data : Bytes) -> Bytes raise ZstdError {
  let src = data[:]
  let src_len = data.length()
  guard src_len >= 4 else { raise ZstdError::UnexpectedEOF }
  let magic = src.unsafe_get(0).to_uint() |
    (src.unsafe_get(1).to_uint() << 8) |
    (src.unsafe_get(2).to_uint() << 16) |
    (src.unsafe_get(3).to_uint() << 24)
  guard magic == ZSTD_MAGIC else {
    raise ZstdError::InvalidHeader("invalid magic number")
  }
  guard src_len >= 5 else { raise ZstdError::UnexpectedEOF }
  let fhd = src.unsafe_get(4).to_int()
  let fcs_flag = (fhd >> 6) & 0x03
  let single_segment = (fhd >> 5) & 0x01
  let has_checksum = (fhd >> 2) & 0x01
  let dict_id_flag = fhd & 0x03
  let mut pos = 5
  let mut window_size = 0
  if single_segment == 0 {
    guard pos < src_len else { raise ZstdError::UnexpectedEOF }
    let wd = src.unsafe_get(pos).to_int()
    pos += 1
    let exponent = (wd >> 3) + 10
    let mantissa = wd & 0x07
    window_size = (1 << exponent) + mantissa * (1 << (exponent - 3))
    guard window_size <= MAX_WINDOW_SIZE else {
      raise ZstdError::WindowTooLarge("window size \{window_size} exceeds max")
    }
  }
  let dict_id_size = match dict_id_flag {
    0 => 0
    1 => 1
    2 => 2
    _ => 4
  }
  guard dict_id_size == 0 else {
    raise ZstdError::InvalidHeader("dictionaries are not supported")
  }
  let fcs_size = match fcs_flag {
    0 => if single_segment == 1 { 1 } else { 0 }
    1 => 2
    2 => 4
    _ => 8
  }
  guard pos + fcs_size <= src_len else { raise ZstdError::UnexpectedEOF }
  let content_size : Int? = match fcs_size {
    0 => None
    1 => {
      let v = src.unsafe_get(pos).to_int()
      pos += 1
      Some(v)
    }
    2 => {
      let v = src.unsafe_get(pos).to_int() |
        (src.unsafe_get(pos + 1).to_int() << 8)
      pos += 2
      Some(v + 256)
    }
    4 => {
      let v = src.unsafe_get(pos).to_int() |
        (src.unsafe_get(pos + 1).to_int() << 8) |
        (src.unsafe_get(pos + 2).to_int() << 16) |
        (src.unsafe_get(pos + 3).to_int() << 24)
      pos += 4
      Some(v)
    }
    _ => {
      let v = src.unsafe_get(pos).to_int() |
        (src.unsafe_get(pos + 1).to_int() << 8) |
        (src.unsafe_get(pos + 2).to_int() << 16) |
        (src.unsafe_get(pos + 3).to_int() << 24)
      pos += 8
      Some(v)
    }
  }
  if single_segment == 1 {
    match content_size {
      Some(cs) => window_size = cs
      None => ()
    }
  }
  let capacity = match content_size {
    Some(cs) => cs
    None => (src_len * 4).max(65536)
  }
  let sink = @blit.Buffer::new(size_hint=capacity)
  let xxh = @checksum.XXH64::new()
  let rep = [1, 4, 8]
  let mut prev_lit_table : ZstdHuffmanTable? = None
  let mut prev_seq_tables : SeqTables? = None
  let mut saw_last_block = false
  while !saw_last_block {
    guard pos + 3 <= src_len else { raise ZstdError::UnexpectedEOF }
    let bh = src.unsafe_get(pos).to_int() |
      (src.unsafe_get(pos + 1).to_int() << 8) |
      (src.unsafe_get(pos + 2).to_int() << 16)
    pos += 3
    let last_block = bh & 1
    let block_type = (bh >> 1) & 3
    let block_size = bh >> 3
    if block_type == BLOCK_TYPE_RAW {
      guard pos + block_size <= src_len else { raise ZstdError::UnexpectedEOF }
      let block_data = Bytes::makei(block_size, fn(i) {
        src.unsafe_get(pos + i)
      })
      sink.write_bytes(block_data)
      xxh.update(block_data[:])
      pos += block_size
    } else if block_type == BLOCK_TYPE_RLE {
      guard pos < src_len else { raise ZstdError::UnexpectedEOF }
      let rle_byte = src.unsafe_get(pos)
      pos += 1
      let block_data = Bytes::make(block_size, rle_byte)
      sink.write_bytes(block_data)
      xxh.update(block_data[:])
    } else if block_type == BLOCK_TYPE_COMPRESSED {
      guard pos + block_size <= src_len else { raise ZstdError::UnexpectedEOF }
      let (block_data, next_lit_table, next_seq_tables) = decompress_block(
        src, pos, block_size, window_size, sink, rep, prev_lit_table, prev_seq_tables,
      )
      prev_lit_table = next_lit_table
      prev_seq_tables = next_seq_tables
      sink.write_bytes(block_data)
      xxh.update(block_data[:])
      pos += block_size
    } else {
      raise ZstdError::CorruptData("reserved block type")
    }
    saw_last_block = last_block == 1
  }
  if has_checksum == 1 {
    guard pos + 4 <= src_len else { raise ZstdError::UnexpectedEOF }
    let expected_cs = src.unsafe_get(pos).to_uint() |
      (src.unsafe_get(pos + 1).to_uint() << 8) |
      (src.unsafe_get(pos + 2).to_uint() << 16) |
      (src.unsafe_get(pos + 3).to_uint() << 24)
    let actual_cs = xxh.checksum64().to_uint()
    guard expected_cs == actual_cs else {
      raise ZstdError::ChecksumMismatch(expected=expected_cs, got=actual_cs)
    }
    pos += 4
  }
  guard pos == src_len else {
    raise ZstdError::CorruptData("trailing bytes after frame end")
  }
  match content_size {
    Some(cs) => {
      guard sink.length() == cs else {
        raise ZstdError::CorruptData("frame content size mismatch")
      }
    }
    None => ()
  }
  sink.to_bytes()
}

///|
fn decompress_block(
  src : BytesView,
  block_start : Int,
  block_size : Int,
  window_size : Int,
  prev_output : @blit.Buffer,
  rep : Array[Int],
  prev_lit_table : ZstdHuffmanTable?,
  prev_seq_tables : SeqTables?,
) -> (Bytes, ZstdHuffmanTable?, SeqTables?) raise ZstdError {
  let block_end = block_start + block_size
  let (lit_data, pos0, next_lit_table) = decode_literals_section(
    src, block_start, block_end, prev_lit_table,
  )
  let mut pos = pos0
  if pos >= block_end {
    return (lit_data, next_lit_table, prev_seq_tables)
  }
  let num_sequences = decode_num_sequences(src, pos, block_end)
  pos += num_sequence_header_bytes(src, pos, block_end)
  if num_sequences == 0 {
    guard pos == block_end else {
      raise ZstdError::CorruptData(
        "unexpected bytes after empty sequence section",
      )
    }
    return (lit_data, next_lit_table, prev_seq_tables)
  }
  guard pos < block_end else { raise ZstdError::UnexpectedEOF }
  let modes = src.unsafe_get(pos).to_int()
  pos += 1
  let (seq_tables, pos_after_tables) = decode_sequence_tables(
    src, pos, block_end, modes, prev_seq_tables,
  )
  let block_data = execute_sequences(
    lit_data,
    num_sequences,
    src[pos_after_tables:block_end],
    seq_tables,
    prev_output,
    rep,
    window_size,
  )
  (block_data, next_lit_table, Some(seq_tables))
}

///|
fn decode_literals_section(
  src : BytesView,
  pos_ : Int,
  block_end : Int,
  prev_lit_table : ZstdHuffmanTable?,
) -> (Bytes, Int, ZstdHuffmanTable?) raise ZstdError {
  let mut pos = pos_
  guard pos < block_end else {
    raise ZstdError::CorruptData("empty compressed block")
  }
  let lit_header = src.unsafe_get(pos).to_int()
  let lit_type = lit_header & 0x03
  if lit_type == 0 {
    let (lit_size, header_bytes) = decode_raw_literal_header(
      src, pos, block_end,
    )
    pos += header_bytes
    guard pos + lit_size <= block_end else {
      raise ZstdError::CorruptData("literals extend past block")
    }
    let literals = Bytes::makei(lit_size, fn(i) { src.unsafe_get(pos + i) })
    pos += lit_size
    return (literals, pos, prev_lit_table)
  }
  if lit_type == 1 {
    let (lit_size, header_bytes) = decode_raw_literal_header(
      src, pos, block_end,
    )
    pos += header_bytes
    guard pos < block_end else { raise ZstdError::UnexpectedEOF }
    let literals = Bytes::make(lit_size, src.unsafe_get(pos))
    pos += 1
    return (literals, pos, prev_lit_table)
  }
  let (lit_size, compressed_size, header_bytes, num_streams) = decode_huffman_literals_header(
    src, pos, block_end,
  )
  pos += header_bytes
  guard pos + compressed_size <= block_end else {
    raise ZstdError::UnexpectedEOF
  }
  let (table, table_size, next_lit_table) = if lit_type == 2 {
    let (decoded_table, consumed) = ZstdHuffmanTable::from_description(
      src[pos:pos + compressed_size],
    )
    (decoded_table, consumed, Some(decoded_table))
  } else {
    match prev_lit_table {
      Some(existing) => (existing, 0, prev_lit_table)
      None =>
        raise ZstdError::CorruptData(
          "treeless literals used without a previous Huffman table",
        )
    }
  }
  guard table_size <= compressed_size else {
    raise ZstdError::CorruptData(
      "Huffman table description exceeds literals block",
    )
  }
  let literals = decode_huffman_literals(
    table,
    src[pos + table_size:pos + compressed_size],
    lit_size,
    num_streams,
  )
  pos += compressed_size
  (literals, pos, next_lit_table)
}

///|
fn decode_raw_literal_header(
  src : BytesView,
  pos : Int,
  block_end : Int,
) -> (Int, Int) raise ZstdError {
  let lit_header = src.unsafe_get(pos).to_int()
  let size_format = (lit_header >> 2) & 0x03
  if size_format == 0 || size_format == 2 {
    return (lit_header >> 3, 1)
  }
  if size_format == 1 {
    guard pos + 1 < block_end else { raise ZstdError::UnexpectedEOF }
    let lit_size = (lit_header >> 4) | (src.unsafe_get(pos + 1).to_int() << 4)
    return (lit_size, 2)
  }
  guard pos + 2 < block_end else { raise ZstdError::UnexpectedEOF }
  let lit_size = (lit_header >> 4) |
    (src.unsafe_get(pos + 1).to_int() << 4) |
    (src.unsafe_get(pos + 2).to_int() << 12)
  (lit_size, 3)
}

///|
fn decode_huffman_literals_header(
  src : BytesView,
  pos : Int,
  block_end : Int,
) -> (Int, Int, Int, Int) raise ZstdError {
  guard pos < block_end else { raise ZstdError::UnexpectedEOF }
  let lit_header = src.unsafe_get(pos).to_int()
  let size_format = (lit_header >> 2) & 0x03
  if size_format == 0 {
    guard pos + 2 < block_end else { raise ZstdError::UnexpectedEOF }
    let b1 = src.unsafe_get(pos + 1).to_int()
    let b2 = src.unsafe_get(pos + 2).to_int()
    ((lit_header >> 4) | ((b1 & 0x3F) << 4), (b1 >> 6) | (b2 << 2), 3, 1)
  } else if size_format == 1 {
    guard pos + 2 < block_end else { raise ZstdError::UnexpectedEOF }
    let b1 = src.unsafe_get(pos + 1).to_int()
    let b2 = src.unsafe_get(pos + 2).to_int()
    ((lit_header >> 4) | ((b1 & 0x3F) << 4), (b1 >> 6) | (b2 << 2), 3, 4)
  } else if size_format == 2 {
    guard pos + 3 < block_end else { raise ZstdError::UnexpectedEOF }
    let b1 = src.unsafe_get(pos + 1).to_int()
    let b2 = src.unsafe_get(pos + 2).to_int()
    let b3 = src.unsafe_get(pos + 3).to_int()
    (
      (lit_header >> 4) | (b1 << 4) | ((b2 & 0x03) << 12),
      (b2 >> 2) | (b3 << 6),
      4,
      4,
    )
  } else {
    guard pos + 4 < block_end else { raise ZstdError::UnexpectedEOF }
    let b1 = src.unsafe_get(pos + 1).to_int()
    let b2 = src.unsafe_get(pos + 2).to_int()
    let b3 = src.unsafe_get(pos + 3).to_int()
    let b4 = src.unsafe_get(pos + 4).to_int()
    (
      (lit_header >> 4) | (b1 << 4) | (b2 << 12) | ((b3 & 0x3F) << 20),
      (b2 >> 6) | (b3 << 2) | (b4 << 10),
      5,
      4,
    )
  }
}

///|
fn decode_num_sequences(
  src : BytesView,
  pos : Int,
  block_end : Int,
) -> Int raise ZstdError {
  guard pos < block_end else { raise ZstdError::UnexpectedEOF }
  let byte0 = src.unsafe_get(pos).to_int()
  if byte0 == 0 {
    return 0
  }
  if byte0 < 128 {
    return byte0
  }
  if byte0 < 255 {
    guard pos + 1 < block_end else { raise ZstdError::UnexpectedEOF }
    return ((byte0 - 128) << 8) + src.unsafe_get(pos + 1).to_int()
  }
  guard pos + 2 < block_end else { raise ZstdError::UnexpectedEOF }
  src.unsafe_get(pos + 1).to_int() +
  (src.unsafe_get(pos + 2).to_int() << 8) +
  0x7F00
}

///|
fn num_sequence_header_bytes(
  src : BytesView,
  pos : Int,
  block_end : Int,
) -> Int raise ZstdError {
  guard pos < block_end else { raise ZstdError::UnexpectedEOF }
  let byte0 = src.unsafe_get(pos).to_int()
  if byte0 == 0 || byte0 < 128 {
    return 1
  }
  if byte0 < 255 {
    guard pos + 1 < block_end else { raise ZstdError::UnexpectedEOF }
    return 2
  }
  guard pos + 2 < block_end else { raise ZstdError::UnexpectedEOF }
  3
}

///|
fn decode_sequence_tables(
  src : BytesView,
  pos_ : Int,
  block_end : Int,
  modes : Int,
  prev_seq_tables : SeqTables?,
) -> (SeqTables, Int) raise ZstdError {
  guard (modes & 0x03) == 0 else {
    raise ZstdError::CorruptData("reserved sequence mode bits are set")
  }
  let mut pos = pos_
  let ll_prev : SeqDecoder? = match prev_seq_tables {
    Some(t) => Some(t.ll)
    None => None
  }
  let of_prev : SeqDecoder? = match prev_seq_tables {
    Some(t) => Some(t.of)
    None => None
  }
  let ml_prev : SeqDecoder? = match prev_seq_tables {
    Some(t) => Some(t.ml)
    None => None
  }
  let (ll, pos1) = decode_sequence_table(
    src,
    pos,
    block_end,
    (modes >> 6) & 0x03,
    35,
    9,
    SeqDecoder::Fse(ll_default_table),
    ll_prev,
    "literal length",
  )
  pos = pos1
  let (of, pos2) = decode_sequence_table(
    src,
    pos,
    block_end,
    (modes >> 4) & 0x03,
    31,
    8,
    SeqDecoder::Fse(of_default_table),
    of_prev,
    "offset",
  )
  pos = pos2
  let (ml, pos3) = decode_sequence_table(
    src,
    pos,
    block_end,
    (modes >> 2) & 0x03,
    52,
    9,
    SeqDecoder::Fse(ml_default_table),
    ml_prev,
    "match length",
  )
  ({ ll, of, ml }, pos3)
}

///|
fn decode_sequence_table(
  src : BytesView,
  pos : Int,
  block_end : Int,
  mode : Int,
  max_symbol : Int,
  max_accuracy_log : Int,
  default_table : SeqDecoder,
  previous : SeqDecoder?,
  kind : String,
) -> (SeqDecoder, Int) raise ZstdError {
  if mode == 0 {
    return (default_table, pos)
  }
  if mode == 1 {
    guard pos < block_end else { raise ZstdError::UnexpectedEOF }
    let symbol = src.unsafe_get(pos).to_int()
    guard symbol <= max_symbol else {
      raise ZstdError::CorruptData("\{kind} RLE symbol is out of range")
    }
    return (SeqDecoder::Rle(symbol), pos + 1)
  }
  if mode == 2 {
    let (table, bytes_read) = build_fse_table_from_description(
      src[pos:block_end],
      max_symbol,
      max_accuracy_log,
    )
    return (SeqDecoder::Fse(table), pos + bytes_read)
  }
  match previous {
    Some(table) => (table, pos)
    None =>
      raise ZstdError::CorruptData(
        "repeat mode used without a previous \{kind} table",
      )
  }
}

///|
fn execute_sequences(
  lit_data : Bytes,
  num_sequences : Int,
  seq_data : BytesView,
  seq_tables : SeqTables,
  prev_output : @blit.Buffer,
  rep : Array[Int],
  window_size : Int,
) -> Bytes raise ZstdError {
  let br = BackwardBitReader::new(seq_data)
  let mut ll_state = init_sequence_state(br, seq_tables.ll)
  let mut of_state = init_sequence_state(br, seq_tables.of)
  let mut ml_state = init_sequence_state(br, seq_tables.ml)
  let block_out = @blit.Buffer::new(
    size_hint=lit_data.length() + num_sequences * 8,
  )
  let mut lit_pos = 0
  let prev_len = prev_output.length()
  for i in 0..<num_sequences {
    let (of_code, of_bits, of_base) = decode_sequence_symbol(
      seq_tables.of,
      of_state,
    )
    guard of_code <= 31 else {
      raise ZstdError::CorruptData("offset code exceeds supported range")
    }
    let offset_value = if of_code > 0 {
      guard br.can_read(of_code) else { raise ZstdError::UnexpectedEOF }
      (1 << of_code) + br.read_bits_checked(of_code).reinterpret_as_int()
    } else {
      1
    }
    let (ml_code, ml_bits, ml_base) = decode_sequence_symbol(
      seq_tables.ml,
      ml_state,
    )
    let match_len = decode_match_length(br, ml_code)
    let (ll_code, ll_bits, ll_base) = decode_sequence_symbol(
      seq_tables.ll,
      ll_state,
    )
    let lit_len = decode_literal_length(br, ll_code)
    if i < num_sequences - 1 {
      ll_state = update_sequence_state(br, seq_tables.ll, ll_bits, ll_base)
      ml_state = update_sequence_state(br, seq_tables.ml, ml_bits, ml_base)
      of_state = update_sequence_state(br, seq_tables.of, of_bits, of_base)
    }
    guard lit_pos + lit_len <= lit_data.length() else {
      raise ZstdError::CorruptData("sequence literals exceed literals section")
    }
    for j in 0..<lit_len {
      block_out.write_byte(lit_data.unsafe_get(lit_pos + j))
    }
    lit_pos += lit_len
    let offset = resolve_offset(rep, offset_value, lit_len)
    let total_len = prev_len + block_out.length()
    guard offset > 0 && offset <= total_len else {
      raise ZstdError::CorruptData("invalid match offset")
    }
    guard window_size == 0 || offset <= window_size else {
      raise ZstdError::CorruptData("match offset exceeds window size")
    }
    for j in 0..<match_len {
      let src_idx = total_len - offset + j % offset
      let byte = if src_idx < prev_len {
        prev_output.get_byte(src_idx)
      } else {
        block_out.get_byte(src_idx - prev_len)
      }
      block_out.write_byte(byte)
    }
  }
  guard br.is_empty() else {
    raise ZstdError::CorruptData("sequence bitstream not fully consumed")
  }
  while lit_pos < lit_data.length() {
    block_out.write_byte(lit_data.unsafe_get(lit_pos))
    lit_pos += 1
  }
  block_out.to_bytes()
}

///|
fn init_sequence_state(
  br : BackwardBitReader,
  decoder : SeqDecoder,
) -> Int raise ZstdError {
  match decoder {
    SeqDecoder::Fse(table) => {
      let state = br.read_bits_checked(table._accuracy_log).reinterpret_as_int()
      ignore(br.reload())
      state
    }
    SeqDecoder::Rle(_) => 0
  }
}

///|
fn decode_sequence_symbol(decoder : SeqDecoder, state : Int) -> (Int, Int, Int) {
  match decoder {
    SeqDecoder::Fse(table) => {
      let (sym, n_bits, base) = fse_decode_symbol(table, state)
      (sym.to_int(), n_bits, base)
    }
    SeqDecoder::Rle(sym) => (sym, 0, 0)
  }
}

///|
fn update_sequence_state(
  br : BackwardBitReader,
  decoder : SeqDecoder,
  n_bits : Int,
  base : Int,
) -> Int raise ZstdError {
  match decoder {
    SeqDecoder::Fse(_) =>
      base + br.read_bits_checked(n_bits).reinterpret_as_int()
    SeqDecoder::Rle(_) => 0
  }
}

///|
fn decode_literal_length(
  br : BackwardBitReader,
  code : Int,
) -> Int raise ZstdError {
  if code < 16 {
    return code
  }
  guard code < ll_extra_bits.length() else {
    raise ZstdError::CorruptData("invalid literal length code")
  }
  let extra = ll_extra_bits.unsafe_get(code)
  if extra > 0 {
    guard br.can_read(extra) else { raise ZstdError::UnexpectedEOF }
  }
  ll_baselines.unsafe_get(code) +
  (if extra > 0 { br.read_bits_checked(extra).reinterpret_as_int() } else { 0 })
}

///|
fn decode_match_length(
  br : BackwardBitReader,
  code : Int,
) -> Int raise ZstdError {
  if code < 32 {
    return code + 3
  }
  guard code < ml_extra_bits.length() else {
    raise ZstdError::CorruptData("invalid match length code")
  }
  let extra = ml_extra_bits.unsafe_get(code)
  if extra > 0 {
    guard br.can_read(extra) else { raise ZstdError::UnexpectedEOF }
  }
  ml_baselines.unsafe_get(code) +
  (if extra > 0 { br.read_bits_checked(extra).reinterpret_as_int() } else { 0 })
}

///|
fn resolve_offset(rep : Array[Int], offset_value : Int, lit_len : Int) -> Int {
  if offset_value > 3 {
    let actual = offset_value - 3
    rep.unsafe_set(2, rep.unsafe_get(1))
    rep.unsafe_set(1, rep.unsafe_get(0))
    rep.unsafe_set(0, actual)
    return actual
  }
  if offset_value == 1 {
    if lit_len == 0 {
      let tmp = rep.unsafe_get(0)
      rep.unsafe_set(0, rep.unsafe_get(1))
      rep.unsafe_set(1, tmp)
      return rep.unsafe_get(0)
    }
    return rep.unsafe_get(0)
  }
  if offset_value == 2 {
    if lit_len == 0 {
      let tmp = rep.unsafe_get(2)
      rep.unsafe_set(2, rep.unsafe_get(1))
      rep.unsafe_set(1, rep.unsafe_get(0))
      rep.unsafe_set(0, tmp)
      return rep.unsafe_get(0)
    }
    let tmp = rep.unsafe_get(1)
    rep.unsafe_set(1, rep.unsafe_get(0))
    rep.unsafe_set(0, tmp)
    return rep.unsafe_get(0)
  }
  if lit_len == 0 {
    let actual = rep.unsafe_get(0) - 1
    rep.unsafe_set(2, rep.unsafe_get(1))
    rep.unsafe_set(1, rep.unsafe_get(0))
    rep.unsafe_set(0, actual)
    return actual
  }
  let tmp = rep.unsafe_get(2)
  rep.unsafe_set(2, rep.unsafe_get(1))
  rep.unsafe_set(1, rep.unsafe_get(0))
  rep.unsafe_set(0, tmp)
  rep.unsafe_get(0)
}
