///|
/// Compresses data using the LZ4 frame format.
pub fn compress(
  data : Bytes,
  options? : FrameOptions = { ..FrameOptions::default() },
) -> Bytes {
  let src = data[:]
  let src_len = data.length()
  let block_max_size = max_block_sizes[DEFAULT_BLOCK_MAX_SIZE_ID]
  let max_output = 23 +
    src_len +
    (src_len / block_max_size + 1) *
    (if options.block_checksum { 20 } else { 16 }) +
    12
  let out = FixedArray::make(max_output, b'\x00')
  let mut pos = 0
  pos += write_frame_header(out, pos, None, options)
  let xxh = @checksum.XXH32::new()
  xxh.update(src)
  let mut src_pos = 0
  let block_buf = FixedArray::make(block_max_size, b'\x00')
  while src_pos < src_len {
    let block_end = if src_pos + block_max_size < src_len {
      src_pos + block_max_size
    } else {
      src_len
    }
    let block_len = block_end - src_pos
    let block_data = src[src_pos:block_end]
    let compressed_size = block_compress(block_data, block_buf)
    let payload_pos = pos + 4
    if compressed_size > 0 && compressed_size < block_len {
      out.unsafe_set(pos, (compressed_size & 0xFF).to_byte())
      out.unsafe_set(pos + 1, ((compressed_size >> 8) & 0xFF).to_byte())
      out.unsafe_set(pos + 2, ((compressed_size >> 16) & 0xFF).to_byte())
      out.unsafe_set(pos + 3, ((compressed_size >> 24) & 0x7F).to_byte())
      pos += 4
      for i in 0..<compressed_size {
        out.unsafe_set(pos + i, block_buf.unsafe_get(i))
      }
      pos += compressed_size
      if options.block_checksum {
        let payload = Bytes::makei(compressed_size, fn(i) {
          out.unsafe_get(payload_pos + i)
        })
        let block_cs = @checksum.xxh32(payload[:])
        out.unsafe_set(pos, (block_cs & 0xFFU).to_byte())
        out.unsafe_set(pos + 1, ((block_cs >> 8) & 0xFFU).to_byte())
        out.unsafe_set(pos + 2, ((block_cs >> 16) & 0xFFU).to_byte())
        out.unsafe_set(pos + 3, ((block_cs >> 24) & 0xFFU).to_byte())
        pos += 4
      }
    } else {
      out.unsafe_set(pos, (block_len & 0xFF).to_byte())
      out.unsafe_set(pos + 1, ((block_len >> 8) & 0xFF).to_byte())
      out.unsafe_set(pos + 2, ((block_len >> 16) & 0xFF).to_byte())
      out.unsafe_set(pos + 3, (((block_len >> 24) & 0x7F) | 0x80).to_byte())
      pos += 4
      for i in 0..<block_len {
        out.unsafe_set(pos + i, block_data.unsafe_get(i))
      }
      pos += block_len
      if options.block_checksum {
        let block_cs = @checksum.xxh32(block_data)
        out.unsafe_set(pos, (block_cs & 0xFFU).to_byte())
        out.unsafe_set(pos + 1, ((block_cs >> 8) & 0xFFU).to_byte())
        out.unsafe_set(pos + 2, ((block_cs >> 16) & 0xFFU).to_byte())
        out.unsafe_set(pos + 3, ((block_cs >> 24) & 0xFFU).to_byte())
        pos += 4
      }
    }
    src_pos = block_end
  }
  let content_cs = if options.content_checksum {
    Some(xxh.checksum())
  } else {
    None
  }
  pos += write_frame_footer(out, pos, content_cs)
  let result = @blit.make_uninit(pos)
  @blit.blit_fixed_array(result, 0, out, 0, pos)
  result.unsafe_reinterpret_as_bytes()
}
