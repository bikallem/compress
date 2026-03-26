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
}

///|
struct Deflater(EncoderState)

///|
pub fn Deflater::new(
  options? : FrameOptions = { ..FrameOptions::default() },
) -> Deflater {
  Deflater({
    header_written: false,
    finished: false,
    options,
    checksum: @checksum.XXH32::new(),
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
      let out = @blit.Buffer::new(
        size_hint=23 +
          chunk.length() +
          (chunk.length() / 65536 + 1) *
          (if s.options.block_checksum { 16 } else { 12 }),
      )
      if !s.header_written {
        write_frame_header_buffer(out, None, s.options)
        s.header_written = true
      }
      s.checksum.update(chunk)
      let block_buf = FixedArray::make(
        max_block_sizes[DEFAULT_BLOCK_MAX_SIZE_ID],
        b'\x00',
      )
      let mut pos = 0
      while pos < chunk.length() {
        let block_end = if pos + max_block_sizes[DEFAULT_BLOCK_MAX_SIZE_ID] <
          chunk.length() {
          pos + max_block_sizes[DEFAULT_BLOCK_MAX_SIZE_ID]
        } else {
          chunk.length()
        }
        let block = chunk[pos:block_end]
        let compressed_size = block_compress(block, block_buf)
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
        pos = block_end
      }
      let bytes = out.to_bytes()
      if bytes.length() > 0 {
        Data(bytes[:])
      } else {
        Ok
      }
    }
    None => {
      s.finished = true
      let out = @blit.Buffer::new(size_hint=32)
      if !s.header_written {
        write_frame_header_buffer(out, None, s.options)
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
