///|
test "compressed blocks can emit RLE literal and sequence modes" {
  let sequences : Array[ZstdSequence] = [
    { lit_len: 1, offset: 4, match_len: 4, actual_offset: 1 },
    { lit_len: 1, offset: 4, match_len: 4, actual_offset: 1 },
  ]
  let literals = FixedArray::make(2, b'A')
  let block = FixedArray::make(128, b'\x00')
  let (size, _, _) = compress_block_from_sequences(
    sequences,
    literals,
    0,
    2,
    block,
    None,
    None,
  )
  assert_true(size > 0)
  assert_eq(block[0].to_int() & 0x03, 1)
  // literal header (1 byte) + repeated literal byte (1 byte) + num_seq (1 byte)
  assert_eq(block[3].to_int(), 0x54)
}

///|
test "compressed blocks can emit repeat sequence modes" {
  let sequences : Array[ZstdSequence] = [
    { lit_len: 1, offset: 4, match_len: 4, actual_offset: 1 },
    { lit_len: 2, offset: 8, match_len: 5, actual_offset: 5 },
  ]
  let literals = FixedArray::makei(3, fn(i) { (i + 1).to_byte() })
  let block = FixedArray::make(256, b'\x00')
  let prev_tables : SeqTables = {
    ll: SeqDecoder::Fse(ll_default_table),
    of: SeqDecoder::Fse(of_default_table),
    ml: SeqDecoder::Fse(ml_default_table),
  }
  let (size, _, next_seq) = compress_block_from_sequences(
    sequences,
    literals,
    0,
    3,
    block,
    None,
    Some(prev_tables),
  )
  assert_true(size > 0)
  // raw literal header (1 byte) + 3 literals + num_seq header (1 byte)
  assert_eq(block[5].to_int(), 0xFC)
  match next_seq {
    Some(_) => ()
    None => fail("expected repeat sequence tables to remain available")
  }
}

///|
test "literal-only blocks can emit treeless literals" {
  let weights = [1, 1]
  let table = ZstdHuffmanTable::from_weights(weights)
  let literals = FixedArray::makei(32, fn(i) { (i & 1).to_byte() })
  let block = FixedArray::make(128, b'\x00')
  let (size, _, _) = compress_literal_only_block(
    literals,
    0,
    32,
    block,
    Some(table),
    None,
  )
  assert_true(size > 0)
  assert_eq(block[0].to_int() & 0x03, 3)
  assert_eq(block[size - 1].to_int(), 0)
}
