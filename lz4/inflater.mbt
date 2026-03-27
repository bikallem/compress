///|
/// Incremental LZ4 decompressor using signal protocol.
///
/// Usage:
///   let d = Inflater::new()
///   d.src(data)
///   loop d.decode() {
///     Await => { d.src(chunk); continue d.decode() }
///     Data(out) => { write(out); continue d.decode() }
///     End => break
///     Error(e) => ...
///   }
/// Call `finish()` once the upstream source reaches EOF so the inflater can
/// distinguish a real end-of-input from an exact frame boundary.
priv enum InflatePhase {
  FrameHeader
  BlockHeader
  BlockBody(Bool, Int)
  ContentChecksum
  AwaitNextFrame
  Done
}

///|
priv struct InflaterState {
  mut input_buf : @blit.Buffer
  mut input_pos : Int
  dict : Dictionary
  mut header : Lz4FrameHeader?
  mut initial_prefix : Bytes
  mut history : @blit.Buffer
  mut frame_output_len : Int
  content_xxh : @checksum.XXH32
  mut phase : InflatePhase
  mut input_finished : Bool
  mut failed : Lz4Error?
  mut sink : @blit.Buffer?
}

///|
struct Inflater(InflaterState)

///|
pub fn Inflater::new(dict? : Bytes = Bytes::default()) -> Inflater {
  Inflater::new_with_dictionary(Dictionary::new(dict))
}

///|
pub fn Inflater::new_with_dictionary(dict : Dictionary) -> Inflater {
  Inflater({
    input_buf: @blit.Buffer::new(),
    input_pos: 0,
    dict,
    header: None,
    initial_prefix: b"",
    history: @blit.Buffer::new(),
    frame_output_len: 0,
    content_xxh: @checksum.XXH32::new(),
    phase: FrameHeader,
    input_finished: false,
    failed: None,
    sink: None,
  })
}

///|
pub fn Inflater::src(self : Inflater, data : BytesView) -> Unit {
  let s = self.0
  if s.phase is Done || s.failed is Some(_) {
    return
  }
  if data.length() > 0 {
    s.input_finished = false
    if s.phase is AwaitNextFrame {
      s.phase = FrameHeader
    }
  }
  s.input_buf.write_bytesview(data)
}

///|
pub fn Inflater::finish(self : Inflater) -> Unit {
  self.0.input_finished = true
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
  if s.phase is Done {
    return End
  }
  for ;; {
    let input = s.input_buf.to_bytes()
    match s.phase {
      FrameHeader => {
        if s.input_pos >= input.length() {
          return if s.input_finished {
            fail_lz4(s, UnexpectedEOF)
          } else {
            Await
          }
        }
        let parsed = try? parse_frame_header(input[s.input_pos:])
        let header = match parsed {
          Ok(header) => header
          Err(UnexpectedEOF) =>
            return if s.input_finished {
              fail_lz4(s, UnexpectedEOF)
            } else {
              Await
            }
          Err(e) => return fail_lz4(s, e)
        }
        let initial_prefix = initial_lz4_prefix(header, s.dict) catch {
          e => return fail_lz4(s, e)
        }
        s.header = Some(header)
        s.initial_prefix = initial_prefix
        s.history = @blit.Buffer::new(size_hint=65536)
        if !header.block_independence && initial_prefix.length() > 0 {
          s.history.write_bytes(initial_prefix)
        }
        s.frame_output_len = 0
        s.content_xxh.reset()
        s.input_pos += header.data_offset
        s.phase = BlockHeader
        compact_lz4_input(s)
        continue
      }
      BlockHeader => {
        let header = match s.header {
          Some(header) => header
          None => return fail_lz4(s, CorruptData("missing frame header"))
        }
        let data = s.input_buf.to_bytes()
        if s.input_pos + 4 > data.length() {
          return if s.input_finished {
            fail_lz4(s, UnexpectedEOF)
          } else {
            Await
          }
        }
        let block_size_raw = lz4_read_u32_le(data[:], s.input_pos)
        s.input_pos += 4
        if block_size_raw == 0U {
          s.phase = ContentChecksum
          compact_lz4_input(s)
          continue
        }
        let is_uncompressed = (block_size_raw & 0x80000000U) != 0U
        let block_size = (block_size_raw & 0x7FFFFFFFU).reinterpret_as_int()
        if block_size > header.block_max_size {
          return fail_lz4(s, CorruptData("block exceeds declared max size"))
        }
        s.phase = BlockBody(is_uncompressed, block_size)
        compact_lz4_input(s)
        continue
      }
      BlockBody(is_uncompressed, block_size) => {
        let header = match s.header {
          Some(header) => header
          None => return fail_lz4(s, CorruptData("missing frame header"))
        }
        let data = s.input_buf.to_bytes()
        let checksum_bytes = if header.has_block_checksum { 4 } else { 0 }
        if s.input_pos + block_size + checksum_bytes > data.length() {
          return if s.input_finished {
            fail_lz4(s, UnexpectedEOF)
          } else {
            Await
          }
        }
        let payload = data[s.input_pos:s.input_pos + block_size]
        if header.has_block_checksum {
          let expected_cs = lz4_read_u32_le(data[:], s.input_pos + block_size)
          let actual_cs = @checksum.xxh32(payload)
          if expected_cs != actual_cs {
            return fail_lz4(
              s,
              ChecksumMismatch(expected=expected_cs, got=actual_cs),
            )
          }
        }
        let block = if is_uncompressed {
          Bytes::makei(block_size, fn(i) { data.unsafe_get(s.input_pos + i) })
        } else {
          let block_buf = FixedArray::make(header.block_max_size, b'\x00')
          let prefix = current_lz4_prefix(header, s.initial_prefix, s.history)
          let result = try? block_decompress_with_history(
            data[:],
            s.input_pos,
            s.input_pos + block_size,
            prefix,
            block_buf,
            0,
            header.block_max_size,
          )
          match result {
            Ok((decoded_len, _)) =>
              Bytes::makei(decoded_len, fn(i) { block_buf.unsafe_get(i) })
            Err(e) => return fail_lz4(s, e)
          }
        }
        s.input_pos += block_size + checksum_bytes
        s.frame_output_len += block.length()
        s.content_xxh.update(block[:])
        if !header.block_independence {
          append_lz4_history(s.history, block)
        }
        s.phase = BlockHeader
        compact_lz4_input(s)
        match s.sink {
          Some(sink) => {
            sink.write_bytes(block)
            continue
          }
          None => return Data(block[:])
        }
      }
      ContentChecksum => {
        let header = match s.header {
          Some(header) => header
          None => return fail_lz4(s, CorruptData("missing frame header"))
        }
        let data = s.input_buf.to_bytes()
        if header.has_content_checksum {
          if s.input_pos + 4 > data.length() {
            return if s.input_finished {
              fail_lz4(s, UnexpectedEOF)
            } else {
              Await
            }
          }
          let expected_cs = lz4_read_u32_le(data[:], s.input_pos)
          let actual_cs = s.content_xxh.checksum()
          if expected_cs != actual_cs {
            return fail_lz4(
              s,
              ChecksumMismatch(expected=expected_cs, got=actual_cs),
            )
          }
          s.input_pos += 4
        }
        match header.content_size {
          Some(expected) =>
            if s.frame_output_len != expected {
              return fail_lz4(s, ContentSizeMismatch)
            }
          None => ()
        }
        if s.input_pos < data.length() {
          s.header = None
          s.initial_prefix = b""
          s.phase = FrameHeader
          compact_lz4_input(s)
          continue
        }
        s.phase = AwaitNextFrame
        compact_lz4_input(s)
        continue
      }
      AwaitNextFrame =>
        if s.input_finished {
          s.phase = Done
          return End
        } else {
          return Await
        }
      Done => return End
    }
  }
}

///|
fn compact_lz4_input(s : InflaterState) -> Unit {
  let input = s.input_buf.to_bytes()
  if s.input_pos == 0 {
    return
  }
  if s.input_pos < input.length() / 2 && s.input_pos < 65536 {
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
fn fail_lz4(s : InflaterState, e : Lz4Error) -> Decode {
  s.failed = Some(e)
  Error(e)
}
