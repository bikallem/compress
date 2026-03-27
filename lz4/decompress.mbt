///|
/// Decompresses LZ4 frame format data.
pub fn decompress(
  data : Bytes,
  dict? : Bytes = Bytes::default(),
) -> Bytes raise Lz4Error {
  decompress_with_dictionary(data, Dictionary::new(dict))
}

///|
/// Decompresses LZ4 frame format data using explicit dictionary metadata.
pub fn decompress_with_dictionary(
  data : Bytes,
  dict : Dictionary,
) -> Bytes raise Lz4Error {
  let src = data[:]
  let sink = @blit.Buffer::new(size_hint=(data.length() * 2).max(65536))
  let mut pos = 0
  while pos < data.length() {
    pos = decompress_frame(src, data, pos, sink, dict)
  }
  sink.to_bytes()
}

///|
fn decompress_frame(
  src : BytesView,
  data : Bytes,
  start : Int,
  sink : @blit.Buffer,
  dict : Dictionary,
) -> Int raise Lz4Error {
  let header = parse_frame_header(src[start:])
  let initial_prefix = initial_lz4_prefix(header, dict)
  let block_buf = FixedArray::make(header.block_max_size, b'\x00')
  let history = @blit.Buffer::new(size_hint=65536)
  if !header.block_independence && initial_prefix.length() > 0 {
    history.write_bytes(initial_prefix)
  }
  let mut pos = start + header.data_offset
  let xxh = @checksum.XXH32::new()
  let mut frame_output_len = 0
  let mut saw_end_mark = false
  while !saw_end_mark {
    guard pos + 4 <= data.length() else { raise Lz4Error::UnexpectedEOF }
    let block_size_raw = lz4_read_u32_le(src, pos)
    pos += 4
    if block_size_raw == 0U {
      saw_end_mark = true
      continue
    }
    let is_uncompressed = (block_size_raw & 0x80000000U) != 0U
    let block_size = (block_size_raw & 0x7FFFFFFFU).reinterpret_as_int()
    guard block_size <= header.block_max_size else {
      raise Lz4Error::CorruptData("block exceeds declared max size")
    }
    guard pos + block_size <= data.length() else {
      raise Lz4Error::UnexpectedEOF
    }
    let payload = data[pos:pos + block_size]
    if header.has_block_checksum {
      guard pos + block_size + 4 <= data.length() else {
        raise Lz4Error::UnexpectedEOF
      }
      let expected_cs = lz4_read_u32_le(src, pos + block_size)
      let actual_cs = @checksum.xxh32(payload)
      guard expected_cs == actual_cs else {
        raise Lz4Error::ChecksumMismatch(expected=expected_cs, got=actual_cs)
      }
    }
    let block_bytes = if is_uncompressed {
      Bytes::makei(block_size, fn(i) { data.unsafe_get(pos + i) })
    } else {
      let prefix = current_lz4_prefix(header, initial_prefix, history)
      let (decoded_len, _) = block_decompress_with_history(
        src,
        pos,
        pos + block_size,
        prefix,
        block_buf,
        0,
        header.block_max_size,
      )
      Bytes::makei(decoded_len, fn(i) { block_buf.unsafe_get(i) })
    }
    sink.write_bytes(block_bytes)
    xxh.update(block_bytes[:])
    frame_output_len += block_bytes.length()
    if !header.block_independence {
      append_lz4_history(history, block_bytes)
    }
    pos += block_size
    if header.has_block_checksum {
      pos += 4
    }
  }
  if header.has_content_checksum {
    guard pos + 4 <= data.length() else { raise Lz4Error::UnexpectedEOF }
    let expected_cs = lz4_read_u32_le(src, pos)
    let actual_cs = xxh.checksum()
    guard expected_cs == actual_cs else {
      raise Lz4Error::ChecksumMismatch(expected=expected_cs, got=actual_cs)
    }
    pos += 4
  }
  match header.content_size {
    Some(expected) =>
      if frame_output_len != expected {
        raise Lz4Error::ContentSizeMismatch
      }
    None => ()
  }
  pos
}

///|
fn initial_lz4_prefix(
  header : Lz4FrameHeader,
  dict : Dictionary,
) -> Bytes raise Lz4Error {
  if dict.data.length() == 0 {
    guard header.dict_id == 0U else {
      raise Lz4Error::InvalidHeader(
        "dictionary id requires external dictionary bytes",
      )
    }
    return b""
  }
  if header.dict_id != 0U && dict.dict_id != header.dict_id {
    raise Lz4Error::InvalidHeader("dictionary id mismatch")
  }
  lz4_dictionary_prefix(dict.data)
}

///|
fn current_lz4_prefix(
  header : Lz4FrameHeader,
  initial_prefix : Bytes,
  history : @blit.Buffer,
) -> BytesView {
  if header.block_independence {
    initial_prefix[:]
  } else {
    history.to_bytes()[:]
  }
}

///|
fn append_lz4_history(history : @blit.Buffer, block : Bytes) -> Unit {
  let current = history.to_bytes()
  let total = current.length() + block.length()
  let keep = if total > 65535 { 65535 } else { total }
  let skip = total - keep
  let next = @blit.Buffer::new(size_hint=keep)
  if skip < current.length() {
    next.write_bytesview(current[skip:])
    next.write_bytes(block)
  } else {
    let block_skip = skip - current.length()
    if block_skip < block.length() {
      next.write_bytesview(block[block_skip:])
    }
  }
  history.reset()
  history.write_bytes(next.to_bytes())
}
