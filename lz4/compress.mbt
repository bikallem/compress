///|
/// Compresses data using the LZ4 frame format.
pub fn compress(data : Bytes) -> Bytes {
  let src = data[:]
  let src_len = data.length()
  let block_max_size = max_block_sizes[DEFAULT_BLOCK_MAX_SIZE_ID]
  // Worst case: header + blocks + footer
  let max_output = 19 + src_len + (src_len / block_max_size + 1) * 16 + 12
  let out = FixedArray::make(max_output, b'\x00')
  let mut pos = 0
  // Write frame header (no content size, matching lz4 CLI default)
  pos += write_frame_header(out, pos, None)
  // Content checksum hasher
  let xxh = @checksum.XXH32::new()
  xxh.update(src)
  // Compress in blocks
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
    // Try to compress
    let compressed_size = block_compress(block_data, block_buf)
    if compressed_size > 0 && compressed_size < block_len {
      // Write compressed block header (size as 32-bit LE, high bit clear)
      out.unsafe_set(pos, (compressed_size & 0xFF).to_byte())
      out.unsafe_set(pos + 1, ((compressed_size >> 8) & 0xFF).to_byte())
      out.unsafe_set(pos + 2, ((compressed_size >> 16) & 0xFF).to_byte())
      out.unsafe_set(pos + 3, ((compressed_size >> 24) & 0x7F).to_byte())
      pos += 4
      // Write compressed data
      for i in 0..<compressed_size {
        out.unsafe_set(pos + i, block_buf.unsafe_get(i))
      }
      pos += compressed_size
    } else {
      // Write uncompressed block (high bit set = uncompressed)
      out.unsafe_set(pos, (block_len & 0xFF).to_byte())
      out.unsafe_set(pos + 1, ((block_len >> 8) & 0xFF).to_byte())
      out.unsafe_set(pos + 2, ((block_len >> 16) & 0xFF).to_byte())
      out.unsafe_set(pos + 3, (((block_len >> 24) & 0x7F) | 0x80).to_byte())
      pos += 4
      // Write raw data
      for i in 0..<block_len {
        out.unsafe_set(pos + i, block_data.unsafe_get(i))
      }
      pos += block_len
    }
    src_pos = block_end
  }
  // Write footer with content checksum
  let content_cs = xxh.checksum()
  pos += write_frame_footer(out, pos, Some(content_cs))
  // Return trimmed result
  let result = @blit.make_uninit(pos)
  @blit.blit_fixed_array(result, 0, out, 0, pos)
  result.unsafe_reinterpret_as_bytes()
}
