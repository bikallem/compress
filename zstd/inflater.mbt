///|
priv enum InflatePhase {
  FrameHeader
  BlockHeader
  BlockBody(Int, Int, Bool)
  Checksum
  Done
}

///|
/// Incremental Zstandard decompressor using signal protocol.
priv struct InflaterState {
  mut input_buf : @blit.Buffer
  mut input_pos : Int
  mut phase : InflatePhase
  mut failed : ZstdError?
  mut sink : @blit.Buffer?
  mut pending_output : Bytes?
  dicts : ZstdDictionarySet
  mut next_raw_dict : Int
  mut frame_dict : ZstdDictionary
  mut header : ZstdFrameHeader?
  mut prev_lit_table : ZstdHuffmanTable?
  mut prev_seq_tables : SeqTables?
  mut rep : Array[Int]
  mut history : @blit.Buffer
  mut total_output : Int
  xxh : @checksum.XXH64
}

///|
struct Inflater(InflaterState)

///|
pub fn Inflater::new(dict? : Bytes = Bytes::default()) -> Inflater {
  let parsed = try? single_dictionary_set(dict)
  match parsed {
    Ok(dicts) => inflate_with_dictionary_set(dicts, None)
    Err(e) => inflate_with_dictionary_set(empty_dictionary_set(), Some(e))
  }
}

///|
pub fn Inflater::new_with_dictionaries(
  dicts : Array[Bytes],
) -> Inflater raise ZstdError {
  inflate_with_dictionary_set(build_dictionary_set(dicts), None)
}

///|
fn inflate_with_dictionary_set(
  dicts : ZstdDictionarySet,
  failed : ZstdError?,
) -> Inflater {
  Inflater({
    input_buf: @blit.Buffer::new(),
    input_pos: 0,
    phase: FrameHeader,
    failed,
    sink: None,
    pending_output: None,
    next_raw_dict: 0,
    frame_dict: empty_dictionary(),
    dicts,
    header: None,
    prev_lit_table: None,
    prev_seq_tables: None,
    rep: default_rep_offsets(),
    history: @blit.Buffer::new(),
    total_output: 0,
    xxh: @checksum.XXH64::new(),
  })
}

///|
pub fn Inflater::src(self : Inflater, data : BytesView) -> Unit {
  if self.0.phase is Done || self.0.failed is Some(_) {
    return
  }
  self.0.input_buf.write_bytesview(data)
}

///|
pub fn Inflater::enable_direct_output(self : Inflater, capacity : Int) -> Unit {
  self.0.sink = Some(@blit.Buffer::new(size_hint=capacity))
}

///|
pub fn Inflater::take_output(self : Inflater) -> Bytes {
  match self.0.sink {
    Some(sink) => sink.to_bytes()
    None => Bytes::default()
  }
}

///|
pub fn Inflater::decode(self : Inflater) -> Decode {
  let s = self.0
  match s.failed {
    Some(e) => return Error(e)
    None => ()
  }
  match s.pending_output {
    Some(out) => {
      s.pending_output = None
      return Data(out[:])
    }
    None => ()
  }
  for ;; {
    match s.failed {
      Some(e) => return Error(e)
      None => ()
    }
    let input = s.input_buf.to_bytes()
    match s.phase {
      Done => return End
      FrameHeader =>
        match try_parse_frame_header(input[s.input_pos:]) {
          NeedMore => return Await
          Skippable(total_bytes) => {
            if s.input_pos + total_bytes > input.length() {
              return Await
            }
            s.input_pos += total_bytes
            compact_input(s)
            continue
          }
          Error(e) => return fail_inflater(s, e)
          Parsed(header, consumed) => {
            s.xxh.reset()
            let (frame_dict, next_raw_dict) = select_frame_dictionary(
              s.dicts,
              header.dict_id,
              s.next_raw_dict,
            ) catch {
              e => return fail_inflater(s, e)
            }
            s.input_pos += consumed
            s.next_raw_dict = next_raw_dict
            s.frame_dict = frame_dict
            s.header = Some(header)
            s.prev_lit_table = frame_dict.lit_table
            s.prev_seq_tables = frame_dict.seq_tables
            s.rep = copy_rep_offsets(frame_dict.rep)
            let cap = match header.content_size {
              Some(cs) => cs
              None => (input.length() * 4).max(65536)
            }
            let history_cap = if header.window_size > 0 &&
              header.window_size < cap {
              header.window_size
            } else {
              cap
            }
            s.history = @blit.Buffer::new(size_hint=history_cap)
            s.total_output = 0
            s.phase = BlockHeader
            compact_input(s)
            continue
          }
        }
      BlockHeader => {
        if s.input_pos + 3 > input.length() {
          return Await
        }
        let bh = input[s.input_pos].to_int() |
          (input[s.input_pos + 1].to_int() << 8) |
          (input[s.input_pos + 2].to_int() << 16)
        s.input_pos += 3
        let last_block = (bh & 1) == 1
        let block_type = (bh >> 1) & 0x03
        let block_size = bh >> 3
        if block_type == 3 {
          return fail_inflater(s, ZstdError::CorruptData("reserved block type"))
        }
        s.phase = BlockBody(block_type, block_size, last_block)
        compact_input(s)
        continue
      }
      BlockBody(block_type, block_size, last_block) => {
        let block = match block_type {
          BLOCK_TYPE_RAW => decode_raw_block(s, input, block_size)
          BLOCK_TYPE_RLE => decode_rle_block(s, input, block_size)
          _ => decode_compressed_block(s, input, block_size)
        }
        match block {
          Err(e) => return fail_inflater(s, e)
          Ok(None) => return Await
          Ok(Some(block_data)) => {
            if last_block {
              s.phase = Checksum
            } else {
              s.phase = BlockHeader
            }
            compact_input(s)
            match emit_block(s, block_data) {
              Some(out) => return Data(out[:])
              None => continue
            }
          }
        }
      }
      Checksum => {
        let header = match s.header {
          Some(h) => h
          None =>
            return fail_inflater(
              s,
              ZstdError::CorruptData("frame ended before header was parsed"),
            )
        }
        if header.has_checksum {
          if s.input_pos + 4 > input.length() {
            return Await
          }
          let expected = read_u32_le(input, s.input_pos)
          let actual = s.xxh.checksum64().to_uint()
          if expected != actual {
            return fail_inflater(
              s,
              ZstdError::ChecksumMismatch(expected~, got=actual),
            )
          }
          s.input_pos += 4
        }
        match header.content_size {
          Some(cs) =>
            if s.total_output != cs {
              return fail_inflater(
                s,
                ZstdError::CorruptData("frame content size mismatch"),
              )
            }
          None => ()
        }
        if s.input_pos < input.length() {
          s.phase = FrameHeader
          compact_input(s)
          continue
        }
        s.phase = Done
        compact_input(s)
        return End
      }
    }
  }
}

///|
fn decode_raw_block(
  s : InflaterState,
  input : Bytes,
  block_size : Int,
) -> Result[Bytes?, ZstdError] {
  if s.input_pos + block_size > input.length() {
    return Ok(None)
  }
  let block = Bytes::makei(block_size, fn(i) { input[s.input_pos + i] })
  s.input_pos += block_size
  Ok(Some(block))
}

///|
fn decode_rle_block(
  s : InflaterState,
  input : Bytes,
  block_size : Int,
) -> Result[Bytes?, ZstdError] {
  if s.input_pos >= input.length() {
    return Ok(None)
  }
  let block = Bytes::make(block_size, input[s.input_pos])
  s.input_pos += 1
  Ok(Some(block))
}

///|
fn decode_compressed_block(
  s : InflaterState,
  input : Bytes,
  block_size : Int,
) -> Result[Bytes?, ZstdError] {
  if s.input_pos + block_size > input.length() {
    return Ok(None)
  }
  let header = match s.header {
    Some(h) => h
    None =>
      return Err(
        ZstdError::CorruptData("compressed block without frame header"),
      )
  }
  let result = try? decompress_block(
    input[:],
    s.input_pos,
    block_size,
    header.window_size,
    s.history,
    s.frame_dict.content[:],
    s.rep,
    s.prev_lit_table,
    s.prev_seq_tables,
  )
  match result {
    Err(e) => Err(e)
    Ok((block, next_lit, next_seq)) => {
      s.input_pos += block_size
      s.prev_lit_table = next_lit
      s.prev_seq_tables = next_seq
      Ok(Some(block))
    }
  }
}

///|
fn emit_block(s : InflaterState, block : Bytes) -> Bytes? {
  if block.length() == 0 {
    return None
  }
  append_decode_history(s, block)
  s.total_output += block.length()
  s.xxh.update(block[:])
  match s.sink {
    Some(sink) => {
      sink.write_bytes(block)
      None
    }
    None => Some(block)
  }
}

///|
fn append_decode_history(s : InflaterState, block : Bytes) -> Unit {
  let header = match s.header {
    Some(header) => header
    None => {
      s.history.write_bytes(block)
      return
    }
  }
  let limit = if header.window_size > 0 {
    header.window_size
  } else {
    s.total_output + block.length()
  }
  if limit <= 0 {
    return
  }
  let history = s.history.to_bytes()
  let total = history.length() + block.length()
  if total <= limit {
    s.history.write_bytes(block)
    return
  }
  let keep = limit
  let skip = total - keep
  let next = @blit.Buffer::new(size_hint=keep)
  if skip < history.length() {
    next.write_bytesview(history[skip:])
    next.write_bytes(block)
  } else {
    let block_skip = skip - history.length()
    if block_skip < block.length() {
      next.write_bytesview(block[block_skip:])
    }
  }
  s.history = next
}

///|
fn compact_input(s : InflaterState) -> Unit {
  let data = s.input_buf.to_bytes()
  if s.input_pos == 0 {
    return
  }
  if s.input_pos < data.length() / 2 && s.input_pos < 65536 {
    return
  }
  let remaining = data.length() - s.input_pos
  let next = @blit.Buffer::new(size_hint=remaining)
  if remaining > 0 {
    next.write_bytesview(data[s.input_pos:])
  }
  s.input_buf = next
  s.input_pos = 0
}

///|
fn fail_inflater(s : InflaterState, e : ZstdError) -> Decode {
  s.failed = Some(e)
  Error(e)
}
