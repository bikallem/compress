///|
/// Decompresses LZ4 frame format data.
pub fn decompress(data : Bytes) -> Bytes raise Lz4Error {
  let src = data[:]
  let sink = @blit.Buffer::new(size_hint=(data.length() * 2).max(65536))
  let mut pos = 0
  while pos < data.length() {
    pos = decompress_frame(src, data, pos, sink)
  }
  sink.to_bytes()
}

///|
fn decompress_frame(
  src : BytesView,
  data : Bytes,
  start : Int,
  sink : @blit.Buffer,
) -> Int raise Lz4Error {
  let (data_pos, content_size, has_content_checksum, block_max_size) = parse_frame_header(
    src[start:],
  )
  let block_buf = FixedArray::make(block_max_size, b'\x00')
  let mut pos = start + data_pos
  let xxh = @checksum.XXH32::new()
  let mut frame_output_len = 0
  let mut saw_end_mark = false
  while !saw_end_mark {
    guard pos + 4 <= data.length() else { raise Lz4Error::UnexpectedEOF }
    let block_size_raw = data.unsafe_get(pos).to_int() |
      (data.unsafe_get(pos + 1).to_int() << 8) |
      (data.unsafe_get(pos + 2).to_int() << 16) |
      (data.unsafe_get(pos + 3).to_int() << 24)
    pos += 4
    if block_size_raw == 0 {
      saw_end_mark = true
      continue
    }
    let is_uncompressed = (block_size_raw & 0x80000000) != 0
    let block_size = block_size_raw & 0x7FFFFFFF
    guard pos + block_size <= data.length() else {
      raise Lz4Error::UnexpectedEOF
    }
    if is_uncompressed {
      let block_bytes = Bytes::makei(block_size, fn(i) {
        data.unsafe_get(pos + i)
      })
      sink.write_bytes(block_bytes)
      xxh.update(block_bytes[:])
      frame_output_len += block_size
    } else {
      let (decoded_len, _) = block_decompress(
        src,
        pos,
        pos + block_size,
        block_buf,
        0,
        block_max_size,
      )
      let decoded_bytes = Bytes::makei(decoded_len, fn(i) {
        block_buf.unsafe_get(i)
      })
      sink.write_bytes(decoded_bytes)
      xxh.update(decoded_bytes[:])
      frame_output_len += decoded_len
    }
    pos += block_size
  }
  if has_content_checksum {
    guard pos + 4 <= data.length() else { raise Lz4Error::UnexpectedEOF }
    let expected_cs = data.unsafe_get(pos).to_uint() |
      (data.unsafe_get(pos + 1).to_uint() << 8) |
      (data.unsafe_get(pos + 2).to_uint() << 16) |
      (data.unsafe_get(pos + 3).to_uint() << 24)
    let actual_cs = xxh.checksum()
    guard expected_cs == actual_cs else {
      raise Lz4Error::ChecksumMismatch(expected=expected_cs, got=actual_cs)
    }
    pos += 4
  }
  match content_size {
    Some(expected) =>
      if frame_output_len != expected {
        raise Lz4Error::ContentSizeMismatch
      }
    None => ()
  }
  pos
}

///|
fn parse_frame_header_prefix(
  data : BytesView,
) -> (Int, Int?, Bool, Int)? raise Lz4Error {
  let result : Result[(Int, Int?, Bool, Int), Lz4Error] = try? parse_frame_header(
    data,
  )
  match result {
    Ok(v) => Some(v)
    Err(e) =>
      match e {
        Lz4Error::UnexpectedEOF => None
        _ => raise e
      }
  }
}

///|
fn decompress_frame_prefix(
  src : BytesView,
  data : Bytes,
  start : Int,
  sink : @blit.Buffer,
) -> Int? raise Lz4Error {
  guard parse_frame_header_prefix(src[start:])
    is Some((data_pos, content_size, has_content_checksum, block_max_size)) else {
    return None
  }
  let block_buf = FixedArray::make(block_max_size, b'\x00')
  let mut pos = start + data_pos
  let xxh = @checksum.XXH32::new()
  let mut frame_output_len = 0
  let mut saw_end_mark = false
  while !saw_end_mark {
    guard pos + 4 <= data.length() else { return None }
    let block_size_raw = data.unsafe_get(pos).to_int() |
      (data.unsafe_get(pos + 1).to_int() << 8) |
      (data.unsafe_get(pos + 2).to_int() << 16) |
      (data.unsafe_get(pos + 3).to_int() << 24)
    pos += 4
    if block_size_raw == 0 {
      saw_end_mark = true
      continue
    }
    let is_uncompressed = (block_size_raw & 0x80000000) != 0
    let block_size = block_size_raw & 0x7FFFFFFF
    guard pos + block_size <= data.length() else { return None }
    if is_uncompressed {
      let block_bytes = Bytes::makei(block_size, fn(i) {
        data.unsafe_get(pos + i)
      })
      sink.write_bytes(block_bytes)
      xxh.update(block_bytes[:])
      frame_output_len += block_size
    } else {
      let (decoded_len, _) = block_decompress(
        src,
        pos,
        pos + block_size,
        block_buf,
        0,
        block_max_size,
      )
      let decoded_bytes = Bytes::makei(decoded_len, fn(i) {
        block_buf.unsafe_get(i)
      })
      sink.write_bytes(decoded_bytes)
      xxh.update(decoded_bytes[:])
      frame_output_len += decoded_len
    }
    pos += block_size
  }
  if has_content_checksum {
    guard pos + 4 <= data.length() else { return None }
    let expected_cs = data.unsafe_get(pos).to_uint() |
      (data.unsafe_get(pos + 1).to_uint() << 8) |
      (data.unsafe_get(pos + 2).to_uint() << 16) |
      (data.unsafe_get(pos + 3).to_uint() << 24)
    let actual_cs = xxh.checksum()
    guard expected_cs == actual_cs else {
      raise Lz4Error::ChecksumMismatch(expected=expected_cs, got=actual_cs)
    }
    pos += 4
  }
  match content_size {
    Some(expected) =>
      if frame_output_len != expected {
        raise Lz4Error::ContentSizeMismatch
      }
    None => ()
  }
  Some(pos)
}

///|
fn decompress_prefix_into(
  data : Bytes,
  sink : @blit.Buffer,
) -> Bool raise Lz4Error {
  let src = data[:]
  let mut pos = 0
  while pos < data.length() {
    guard decompress_frame_prefix(src, data, pos, sink) is Some(next) else {
      return false
    }
    pos = next
  }
  true
}
