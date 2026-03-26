///|
/// Incremental LZ4 compressor using signal protocol.
///
/// Usage:
///   let d = Deflater::new()
///   match d.encode(Some(data)) { Ok => ...; Data(out) => ... }
///   match d.encode(None) { Data(out) => ...; End => ... }
priv struct EncoderState {
  mut header_written : Bool
  mut finished : Bool
  options : FrameOptions
  checksum : @checksum.XXH32
  content_size : Int?
  mut seen_len : Int
  history : @blit.Buffer
}

///|
struct Deflater(EncoderState)

///|
pub fn Deflater::new(
  options? : FrameOptions = { ..FrameOptions::default() },
) -> Deflater {
  Deflater::new_with_content_size(-1, options~)
}

///|
/// Creates a streaming LZ4 deflater that writes the optional content-size
/// field when the caller knows the final uncompressed size up front.
pub fn Deflater::new_with_content_size(
  content_size : Int,
  options? : FrameOptions = { ..FrameOptions::default() },
) -> Deflater {
  let known_size = if content_size >= 0 { Some(content_size) } else { None }
  Deflater({
    header_written: false,
    finished: false,
    options,
    checksum: @checksum.XXH32::new(),
    content_size: known_size,
    seen_len: 0,
    history: @blit.Buffer::new(size_hint=65535),
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
      match s.content_size {
        Some(expected) =>
          if s.seen_len + chunk.length() > expected {
            return Error(CorruptData("lz4 input exceeds declared content size"))
          }
        None => ()
      }
      let block_max_size = block_max_size_bytes(s.options.block_max_size)
      let out = @blit.Buffer::new(
        size_hint=(if s.header_written {
            0
          } else {
            frame_header_length(s.content_size, s.options)
          }) +
          chunk.length() +
          (chunk.length() / block_max_size + 1) *
          (if s.options.block_checksum { 16 } else { 12 }),
      )
      if !s.header_written {
        write_frame_header_buffer(out, s.content_size, s.options)
        s.header_written = true
      }
      s.checksum.update(chunk)
      let block_buf = FixedArray::make(block_max_size, b'\x00')
      let mut pos = 0
      while pos < chunk.length() {
        let block_end = if pos + block_max_size < chunk.length() {
          pos + block_max_size
        } else {
          chunk.length()
        }
        let block = chunk[pos:block_end]
        let compressed_size = if s.options.block_independence {
          block_compress(block, block_buf)
        } else {
          block_compress_with_history(s.history.to_bytes()[:], block, block_buf)
        }
        if compressed_size > 0 && compressed_size < block.length() {
          write_block_header_buffer(out, compressed_size, false)
          write_fixed_array_bytes(out, block_buf, compressed_size)
          if s.options.block_checksum {
            write_u32_le_buffer(
              out,
              @checksum.xxh32(
                fixed_array_prefix_view(block_buf, compressed_size),
              ),
            )
          }
        } else {
          write_block_header_buffer(out, block.length(), true)
          out.write_bytesview(block)
          if s.options.block_checksum {
            write_u32_le_buffer(out, @checksum.xxh32(block))
          }
        }
        if !s.options.block_independence {
          append_lz4_deflater_history(s.history, block)
        }
        pos = block_end
      }
      s.seen_len += chunk.length()
      let bytes = out.to_bytes()
      if bytes.length() > 0 {
        Data(bytes[:])
      } else {
        Ok
      }
    }
    None => {
      match s.content_size {
        Some(expected) =>
          if s.seen_len != expected {
            return Error(
              CorruptData(
                "lz4 input length does not match declared content size",
              ),
            )
          }
        None => ()
      }
      s.finished = true
      let out = @blit.Buffer::new(size_hint=32)
      if !s.header_written {
        write_frame_header_buffer(out, s.content_size, s.options)
        s.header_written = true
      }
      let content_cs = if s.options.content_checksum {
        Some(s.checksum.checksum())
      } else {
        None
      }
      write_frame_footer_buffer(out, content_cs)
      let bytes = out.to_bytes()
      if bytes.length() > 0 {
        Data(bytes[:])
      } else {
        End
      }
    }
  }
}

///|
fn write_frame_header_buffer(
  dst : @blit.Buffer,
  content_size : Int?,
  options : FrameOptions,
) -> Unit {
  let temp = FixedArray::make(23, b'\x00')
  let written = write_frame_header(temp, 0, content_size, options)
  for i in 0..<written {
    dst.write_byte(temp.unsafe_get(i))
  }
}

///|
fn write_frame_footer_buffer(
  dst : @blit.Buffer,
  content_checksum : UInt?,
) -> Unit {
  let temp = FixedArray::make(8, b'\x00')
  let written = write_frame_footer(temp, 0, content_checksum)
  for i in 0..<written {
    dst.write_byte(temp.unsafe_get(i))
  }
}

///|
fn write_block_header_buffer(
  dst : @blit.Buffer,
  block_size : Int,
  is_uncompressed : Bool,
) -> Unit {
  let flag = if is_uncompressed { 0x80000000 } else { 0 }
  let raw = block_size | flag
  dst.write_byte((raw & 0xFF).to_byte())
  dst.write_byte(((raw >> 8) & 0xFF).to_byte())
  dst.write_byte(((raw >> 16) & 0xFF).to_byte())
  dst.write_byte(((raw >> 24) & 0xFF).to_byte())
}

///|
fn write_fixed_array_bytes(
  dst : @blit.Buffer,
  src : FixedArray[Byte],
  len : Int,
) -> Unit {
  for i in 0..<len {
    dst.write_byte(src.unsafe_get(i))
  }
}

///|
fn fixed_array_prefix_view(src : FixedArray[Byte], len : Int) -> BytesView {
  Bytes::makei(len, fn(i) { src.unsafe_get(i) })[:]
}

///|
fn write_u32_le_buffer(dst : @blit.Buffer, value : UInt) -> Unit {
  dst.write_byte((value & 0xFFU).to_byte())
  dst.write_byte(((value >> 8) & 0xFFU).to_byte())
  dst.write_byte(((value >> 16) & 0xFFU).to_byte())
  dst.write_byte(((value >> 24) & 0xFFU).to_byte())
}

///|
fn append_lz4_deflater_history(
  history : @blit.Buffer,
  block : BytesView,
) -> Unit {
  let current = history.to_bytes()
  let total = current.length() + block.length()
  let keep = if total > 65535 { 65535 } else { total }
  let skip = total - keep
  let next = @blit.Buffer::new(size_hint=keep)
  if skip < current.length() {
    next.write_bytesview(current[skip:])
    next.write_bytesview(block)
  } else {
    let block_skip = skip - current.length()
    if block_skip < block.length() {
      next.write_bytesview(block[block_skip:])
    }
  }
  history.reset()
  history.write_bytes(next.to_bytes())
}
