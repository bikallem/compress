///|
/// Decompresses LZ4 frame format data.
pub fn decompress(data : Bytes) -> Bytes raise Lz4Error {
  let src = data[:]
  let (data_pos, content_size, has_content_checksum, block_max_size) = parse_frame_header(
    src,
  )
  let initial_capacity = match content_size {
    Some(size) => size
    None => (data.length() * 2).max(block_max_size)
  }
  let sink = @output_sink.OutputSink::new(initial_capacity)
  // Temporary buffer for decompressed blocks
  let block_buf = FixedArray::make(block_max_size, b'\x00')
  let mut pos = data_pos
  let xxh = @checksum.XXH32::new()
  // Read blocks
  while pos + 4 <= data.length() {
    let block_size_raw = data[pos].to_int() |
      (data[pos + 1].to_int() << 8) |
      (data[pos + 2].to_int() << 16) |
      (data[pos + 3].to_int() << 24)
    pos += 4
    // End mark
    if block_size_raw == 0 {
      break
    }
    let is_uncompressed = (block_size_raw & 0x80000000) != 0
    let block_size = block_size_raw & 0x7FFFFFFF
    guard pos + block_size <= data.length() else {
      raise Lz4Error::UnexpectedEOF
    }
    if is_uncompressed {
      let block_bytes = Bytes::makei(block_size, fn(i) { data[pos + i] })
      sink.write_bytes(block_bytes)
      xxh.update(block_bytes[:])
    } else {
      let (decoded_len, _) = block_decompress(
        src, pos, pos + block_size, block_buf, 0, block_max_size,
      )
      let decoded_bytes = Bytes::makei(decoded_len, fn(i) { block_buf[i] })
      sink.write_bytes(decoded_bytes)
      xxh.update(decoded_bytes[:])
    }
    pos += block_size
  }
  // Verify content checksum
  if has_content_checksum {
    guard pos + 4 <= data.length() else { raise Lz4Error::UnexpectedEOF }
    let expected_cs = data[pos].to_uint() |
      (data[pos + 1].to_uint() << 8) |
      (data[pos + 2].to_uint() << 16) |
      (data[pos + 3].to_uint() << 24)
    let actual_cs = xxh.checksum()
    guard expected_cs == actual_cs else {
      raise Lz4Error::ChecksumMismatch(expected=expected_cs, got=actual_cs)
    }
  }
  // Verify content size
  let result = sink.to_bytes()
  match content_size {
    Some(expected) => {
      if result.length() != expected {
        raise Lz4Error::ContentSizeMismatch
      }
    }
    None => ()
  }
  result
}
