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
  checksum : @checksum.XXH32
}

///|
struct Deflater(EncoderState)

///|
pub fn Deflater::new() -> Deflater {
  Deflater({
    header_written: false,
    finished: false,
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
        size_hint=19 + chunk.length() + (chunk.length() / 65536 + 1) * 12,
      )
      if !s.header_written {
        write_frame_header_buffer(out, None)
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
          for i in 0..<compressed_size {
            out.write_byte(block_buf.unsafe_get(i))
          }
        } else {
          write_block_header_buffer(out, block.length(), true)
          out.write_bytesview(block)
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
        write_frame_header_buffer(out, None)
        s.header_written = true
      }
      write_frame_footer_buffer(out, Some(s.checksum.checksum()))
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
fn write_frame_header_buffer(dst : @blit.Buffer, content_size : Int?) -> Unit {
  let temp = FixedArray::make(19, b'\x00')
  let written = write_frame_header(temp, 0, content_size)
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
