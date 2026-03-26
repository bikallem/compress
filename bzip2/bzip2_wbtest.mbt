///|
fn bzip2_compress_randomized_for_test(
  data : Bytes,
  level? : Int = 9,
) -> Bytes raise Bzip2Error {
  guard level >= 1 && level <= 9 else {
    raise Bzip2Error::CorruptData("invalid bzip2 level: must be 1-9")
  }
  let bw = Bzip2BitWriter::new(size_hint=data.length())
  bw.write_byte(BZIP2_MAGIC1)
  bw.write_byte(BZIP2_MAGIC2)
  bw.write_byte(b'h')
  bw.write_byte((b'0'.to_int() + level).to_byte())
  let block_size = level * 100000
  let mut stream_crc = 0U
  let mut offset = 0
  while offset < data.length() {
    let end = if offset + block_size < data.length() {
      offset + block_size
    } else {
      data.length()
    }
    let rle1 = rle1_encode(data, offset, end)
    let randomized = bzip2_apply_randomization(rle1)
    let (bwt_data, orig_ptr) = bwt_transform(randomized)
    let (symbols, num_in_use, in_use) = mtf_rle2_encode(bwt_data)
    let block_crc = bzip2_crc32_range(data, offset, end)
    write_block(
      bw,
      symbols,
      num_in_use,
      in_use,
      orig_ptr,
      block_crc,
      randomized=true,
    )
    stream_crc = ((stream_crc << 1) | (stream_crc >> 31)) ^ block_crc
    offset = end
  }
  bw.write_bits(0x177245U, 24)
  bw.write_bits(0x385090U, 24)
  bw.write_bits(stream_crc >> 16, 16)
  bw.write_bits(stream_crc & 0xFFFFU, 16)
  bw.flush()
  bw.to_bytes()
}

///|
test "bzip2 decompress randomized block" {
  let original = b"Randomized bzip2 block fixture repeated repeated repeated."
  let compressed = bzip2_compress_randomized_for_test(original)
  let decompressed = decompress(compressed)
  assert_eq(decompressed, original)
}
