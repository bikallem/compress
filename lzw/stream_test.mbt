///|
async test "compress streams from reader to writer" {
  let original = Bytes::makei(4096, fn(i) { (i % 251).to_byte() })
  let src = @ibytes.BytesReader::new(original)
  let dst = @ibytes.BytesWriter::new()
  @lzw.compress(src, dst, @lzw.LSB, 8)
  let compressed = dst.content()
  let restored = @lzw.decompress_bytes(compressed, @lzw.LSB, 8)
  assert_eq(restored, original)
}

///|
async test "decompress streams from reader to writer" {
  let original = Bytes::makei(4096, fn(i) { (i % 193).to_byte() })
  let compressed = @lzw.compress_bytes(original, @lzw.MSB, 8)
  let src = @ibytes.BytesReader::new(compressed)
  let dst = @ibytes.BytesWriter::new()
  @lzw.decompress(src, dst, @lzw.MSB, 8)
  assert_eq(dst.content(), original)
}

///|
async test "compress and decompress via io.pipe" {
  let original = Bytes::makei(5000, fn(i) { (i % 251).to_byte() })
  let (compressed_read, compressed_write) = @io.pipe()
  let (source_read, source_write) = @io.pipe()

  @moonasync.with_task_group(root => {
    root.spawn_bg(() => {
      source_write.write(original)
      source_write.close()
    })
    root.spawn_bg(() => {
      @lzw.compress(source_read, compressed_write, @lzw.LSB, 8)
      compressed_write.close()
    })
    let compressed = compressed_read.read_all().binary()
    let restored = @lzw.decompress_bytes(compressed, @lzw.LSB, 8)
    assert_eq(restored, original)
  })
}

///|
async test "decompress consumes incremental input" {
  let original = Bytes::makei(5000, fn(i) { (i % 233).to_byte() })
  let compressed = @lzw.compress_bytes(original, @lzw.LSB, 8)
  let (compressed_read, compressed_write) = @io.pipe()
  let dest = @ibytes.BytesWriter::new()

  @moonasync.with_task_group(root => {
    root.spawn_bg(() => {
      let mut offset = 0
      while offset < compressed.length() {
        let end = if offset + 17 < compressed.length() {
          offset + 17
        } else {
          compressed.length()
        }
        compressed_write.write(compressed[offset:end])
        offset = end
      }
      compressed_write.close()
    })
    @lzw.decompress(compressed_read, dest, @lzw.LSB, 8)
  })

  assert_eq(dest.content(), original)
}
