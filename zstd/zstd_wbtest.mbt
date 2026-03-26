///|
test "compressed blocks can emit RLE literal and sequence modes" {
  let sequences : Array[ZstdSequence] = [
    { lit_len: 1, offset: 4, match_len: 4, actual_offset: 1 },
    { lit_len: 1, offset: 4, match_len: 4, actual_offset: 1 },
  ]
  let literals = FixedArray::make(2, b'A')
  let block = FixedArray::make(128, b'\x00')
  let size = compress_block_from_sequences(sequences, literals, 0, 2, block)
  assert_true(size > 0)
  assert_eq(block[0].to_int() & 0x03, 1)
  // literal header (1 byte) + repeated literal byte (1 byte) + num_seq (1 byte)
  assert_eq(block[3].to_int(), 0x54)
}
