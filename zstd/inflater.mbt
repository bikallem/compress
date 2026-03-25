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
  dict : ZstdDictionary
  mut header : ZstdFrameHeader?
  mut prev_lit_table : ZstdHuffmanTable?
  mut prev_seq_tables : SeqTables?
  mut rep : Array[Int]
  mut history : @blit.Buffer
  xxh : @checksum.XXH64
}

///|
struct Inflater(InflaterState)

///|
pub fn Inflater::new(dict? : Bytes = Bytes::default()) -> Inflater {
  let parsed = try? parse_dictionary_bytes(dict)
  match parsed {
    Ok(dict) =>
      Inflater({
        input_buf: @blit.Buffer::new(),
        input_pos: 0,
        phase: FrameHeader,
        failed: None,
        sink: None,
        pending_output: None,
        dict,
        header: None,
        prev_lit_table: None,
        prev_seq_tables: None,
        rep: default_rep_offsets(),
        history: @blit.Buffer::new(),
        xxh: @checksum.XXH64::new(),
      })
    Err(e) =>
      Inflater({
        input_buf: @blit.Buffer::new(),
        input_pos: 0,
        phase: Done,
        failed: Some(e),
        sink: None,
        pending_output: None,
        dict: empty_dictionary(),
        header: None,
        prev_lit_table: None,
        prev_seq_tables: None,
        rep: default_rep_offsets(),
        history: @blit.Buffer::new(),
        xxh: @checksum.XXH64::new(),
      })
  }
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
          Error(e) => return fail_inflater(s, e)
          Parsed(header, consumed) => {
            if header.dict_id != 0U {
              if s.dict.content.length() == 0 {
                return fail_inflater(
                  s,
                  ZstdError::InvalidHeader(
                    "dictionary id \{header.dict_id} requires external dictionary",
                  ),
                )
              }
              if s.dict.dict_id != 0U && s.dict.dict_id != header.dict_id {
                return fail_inflater(
                  s,
                  ZstdError::InvalidHeader("dictionary id mismatch"),
                )
              }
            }
            s.input_pos += consumed
            s.header = Some(header)
            s.prev_lit_table = s.dict.lit_table
            s.prev_seq_tables = s.dict.seq_tables
            s.rep = copy_rep_offsets(s.dict.rep)
            let cap = match header.content_size {
              Some(cs) => cs
              None => (input.length() * 4).max(65536)
            }
            s.history = @blit.Buffer::new(size_hint=cap)
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
            if s.history.length() != cs {
              return fail_inflater(
                s,
                ZstdError::CorruptData("frame content size mismatch"),
              )
            }
          None => ()
        }
        if s.input_pos != input.length() {
          return fail_inflater(
            s,
            ZstdError::CorruptData("trailing bytes after frame end"),
          )
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
    s.dict.content[:],
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
  s.history.write_bytes(block)
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
