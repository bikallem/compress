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
test "compressed blocks can emit custom sequence tables" {
  let sequences : Array[ZstdSequence] = []
  for i in 0..<1024 {
    if i < 896 {
      sequences.push({ lit_len: 0, offset: 4, match_len: 4, actual_offset: 1 })
    } else {
      sequences.push({ lit_len: 1, offset: 8, match_len: 5, actual_offset: 5 })
    }
  }
  let literals = FixedArray::make(256, b'A')
  let block = FixedArray::make(8192, b'\x00')
  let (size, _, next_seq) = compress_block_from_sequences(
    sequences,
    literals,
    0,
    128,
    block,
    None,
    None,
  )
  assert_true(size > 0)
  let lit_size = raw_literal_header_size(128) + 128
  let header_tmp = FixedArray::make(4, b'\x00')
  let num_seq_size = write_num_sequences_header(
    header_tmp,
    0,
    sequences.length(),
  )
  let modes = block[lit_size + num_seq_size].to_int()
  let ll_mode = (modes >> 6) & 0x03
  let of_mode = (modes >> 4) & 0x03
  let ml_mode = (modes >> 2) & 0x03
  assert_true(ll_mode == 2 || of_mode == 2 || ml_mode == 2)
  match next_seq {
    Some(_) => ()
    None => fail("expected sequence tables to remain available")
  }
}

///|
test "custom FSE headers round-trip through the decoder" {
  let codes = FixedArray::make(1024, 0)
  for i in 0..<1024 {
    codes[i] = if i < 896 { 0 } else { 1 }
  }
  let plan = build_custom_fse_plan(codes, codes.length(), 35, 9)
  match plan {
    Some(plan) =>
      match
        write_fse_ncount(
          plan.norm_counts,
          plan.actual_max_symbol,
          plan.table_log,
        ) {
        Some(header) => {
          let (decoded, actual_max, table_log, bytes_read) = read_ncount(
            header[:],
            35,
            9,
          )
          assert_eq(bytes_read, header.length())
          assert_eq(actual_max, plan.actual_max_symbol)
          assert_eq(table_log, plan.table_log)
          for sym in 0..<=actual_max {
            assert_eq(decoded[sym], plan.norm_counts[sym])
          }
        }
        None => fail("expected custom FSE header bytes")
      }
    None => fail("expected custom FSE plan")
  }
}

///|
test "custom FSE tables round-trip symbol streams" {
  let codes = FixedArray::make(1024, 0)
  for i in 0..<1024 {
    codes[i] = if i < 896 { 0 } else { 1 }
  }
  let plan = build_custom_fse_plan(codes, codes.length(), 35, 9)
  match plan {
    Some(plan) => {
      let ctable = build_fse_ctable(
        plan.norm_counts,
        plan.actual_max_symbol,
        plan.table_log,
      )
      let table = FseTable::build(
        plan.norm_counts,
        plan.actual_max_symbol,
        plan.table_log,
      )
      let temp = FixedArray::make(4096, b'\x00')
      let bw = FseBitWriter::new(temp.length())
      let mut state = fse_init_state(ctable, codes[codes.length() - 1])
      for i = codes.length() - 2; i >= 0; i = i - 1 {
        state = fse_encode_symbol(ctable, bw, state, codes[i])
      }
      fse_flush_state(bw, state, ctable.table_log)
      bw.close()
      let size = bw.copy_to(temp, 0)
      let encoded = Bytes::makei(size, fn(i) { temp[i] })
      let br = BackwardBitReader::new(encoded[:])
      let decoder = SeqDecoder::Fse(table)
      let mut decoded_state = init_sequence_state(br, decoder)
      for i in 0..<codes.length() {
        let (sym, bits, base) = decode_sequence_symbol(decoder, decoded_state)
        assert_eq(sym, codes[i])
        if i < codes.length() - 1 {
          decoded_state = update_sequence_state(br, decoder, bits, base)
        }
      }
      assert_true(br.is_empty())
    }
    None => fail("expected custom FSE plan")
  }
}

///|
test "custom literal tables can emit FSE-compressed Huffman descriptions" {
  let literals = FixedArray::make(4096, b'\x00')
  for i in 0..<literals.length() {
    if i % 53 == 0 {
      literals[i] = b'\xFF'
    } else if i % 97 == 0 {
      literals[i] = b'\x80'
    } else if i % 29 == 0 {
      literals[i] = b'\x01'
    }
  }
  let original = Bytes::makei(literals.length(), fn(i) { literals[i] })
  match build_huffman_literal_table_info(literals, 0, literals.length()) {
    Some(info) => {
      assert_eq(info.highest_symbol, 255)
      match write_direct_huffman_table_description(info) {
        Some(_) => fail("direct Huffman description should be unavailable")
        None => ()
      }
      match write_fse_huffman_table_description(info) {
        Some(desc) => {
          assert_true(desc[0].to_int() < 128)
          let (table, bytes_read) = ZstdHuffmanTable::from_description(desc[:])
          assert_eq(bytes_read, desc.length())
          assert_eq(table.max_bits, info.table.max_bits)
          assert_eq(table.entries.length(), info.table.entries.length())
          for i in 0..<table.entries.length() {
            assert_eq(table.entries[i], info.table.entries[i])
          }
        }
        None => fail("expected FSE-compressed Huffman description")
      }
      match try_build_custom_literal_candidate(literals, 0, literals.length()) {
        Some(candidate) => {
          let (decoded, pos, next_table) = decode_literals_section(
            candidate.bytes[:],
            0,
            candidate.bytes.length(),
            None,
          )
          assert_eq(pos, candidate.bytes.length())
          assert_eq(decoded, original)
          match next_table {
            Some(table) => {
              assert_eq(table.max_bits, info.table.max_bits)
              assert_eq(table.entries.length(), info.table.entries.length())
              for i in 0..<table.entries.length() {
                assert_eq(table.entries[i], info.table.entries[i])
              }
            }
            None => fail("expected literal section to carry a custom table")
          }
        }
        None => fail("expected custom literal candidate")
      }
    }
    None => fail("expected custom literal table info")
  }
}

///|
test "zstd hash uses unsigned little-endian words" {
  let data : Bytes = b"\xff\x80\xaa\xcc\x11"
  let raw = data[0].to_uint() |
    (data[1].to_uint() << 8) |
    (data[2].to_uint() << 16) |
    (data[3].to_uint() << 24)
  let expected = ((raw * 0x9E3779B1U) >> (32 - ZSTD_HASH_BITS)).reinterpret_as_int()
  assert_eq(zstd_hash(data[:], 0), expected)
}

///|
fn zstd_archive_fixture() -> Bytes {
  let long = b"ABCDabcdefghijklmnopqrstuvwxyz0123456789--long-match-anchor--"
  let buf = @blit.Buffer::new()
  buf.write_bytes(long)
  for i in 0..<23 {
    buf.write_bytes(b"ABCDzzzz")
    buf.write_byte((i % 251).to_byte())
    buf.write_bytes(b"|")
  }
  buf.write_bytes(long)
  buf.to_bytes()
}

///|
test "zstd archived search preserves older long anchors at shallow tiers" {
  let data = zstd_archive_fixture()
  let long = b"ABCDabcdefghijklmnopqrstuvwxyz0123456789--long-match-anchor--"
  let src = data[:]
  let hash_table = FixedArray::make(
    ZSTD_HASH_SIZE * ZSTD_MAX_HASH_CANDIDATES,
    -1,
  )
  let hash_archive = FixedArray::make(
    ZSTD_HASH_SIZE * ZSTD_MAX_HASH_ARCHIVE_CANDIDATES,
    -1,
  )
  let starts : Array[Int] = [0]
  let mut pos = long.length()
  for _ in 0..<23 {
    starts.push(pos)
    pos += 10
  }
  let ip = data.length() - long.length()
  for start in starts {
    insert_hash_candidate(
      src,
      data.length(),
      hash_table,
      hash_archive,
      zstd_hash(src, start),
      start,
    )
  }
  let hash = zstd_hash(src, ip)
  let shallow_archive = find_best_match(
    src,
    ip,
    data.length(),
    hash_table,
    hash_archive,
    hash,
    [1, 4, 8],
    {
      lazy_steps: 4,
      max_hash_candidates: 12,
      nice_match: 160,
      archive_candidates: 2,
    },
  )
  let medium_archive = find_best_match(
    src,
    ip,
    data.length(),
    hash_table,
    hash_archive,
    hash,
    [1, 4, 8],
    {
      lazy_steps: 4,
      max_hash_candidates: 12,
      nice_match: 160,
      archive_candidates: 4,
    },
  )
  let deep_archive = find_best_match(
    src,
    ip,
    data.length(),
    hash_table,
    hash_archive,
    hash,
    [1, 4, 8],
    {
      lazy_steps: 6,
      max_hash_candidates: 16,
      nice_match: 224,
      archive_candidates: 8,
    },
  )
  assert_eq(shallow_archive.length, long.length())
  assert_eq(medium_archive.length, long.length())
  assert_true(deep_archive.length >= shallow_archive.length)
  assert_eq(medium_archive.length, long.length())
}

///|
test "custom literal blocks round-trip through the decoder" {
  let pattern = b"aaaaabbbbcccddeeffgghhii jjkkllmmnnooppqqrrssttuu"
  let literals = FixedArray::makei(320, fn(i) { pattern[i % pattern.length()] })
  let block = FixedArray::make(2048, b'\x00')
  let (size, _, _) = compress_literal_only_block(
    literals,
    0,
    literals.length(),
    block,
    None,
    None,
  )
  let frame = FixedArray::make(size + 32, b'\x00')
  let mut pos = write_zstd_frame_header(frame, 0, literals.length(), 0U)
  pos = write_block_header_fixed(frame, pos, true, BLOCK_TYPE_COMPRESSED, size)
  for i in 0..<size {
    frame[pos + i] = block[i]
  }
  pos += size
  let xxh = @checksum.XXH64::new()
  let original = Bytes::makei(literals.length(), fn(i) { literals[i] })
  xxh.update(original[:])
  let checksum = xxh.checksum64().to_uint()
  frame[pos] = (checksum & 0xFFU).to_byte()
  frame[pos + 1] = ((checksum >> 8) & 0xFFU).to_byte()
  frame[pos + 2] = ((checksum >> 16) & 0xFFU).to_byte()
  frame[pos + 3] = ((checksum >> 24) & 0xFFU).to_byte()
  pos += 4
  let compressed = Bytes::makei(pos, fn(i) { frame[i] })
  assert_eq(decompress(compressed), original)
}

///|
test "custom sequence blocks round-trip through the decoder" {
  let sequences : Array[ZstdSequence] = [
    { lit_len: 16, offset: 19, match_len: 16, actual_offset: 16 },
  ]
  for i in 0..<1023 {
    if i < 895 {
      sequences.push({
        lit_len: 0,
        offset: 19,
        match_len: 16,
        actual_offset: 16,
      })
    } else {
      sequences.push({ lit_len: 1, offset: 11, match_len: 8, actual_offset: 8 })
    }
  }
  let literals = FixedArray::make(144, b'q')
  let seed = b"abcdefghijklmnop"
  for i in 0..<seed.length() {
    literals[i] = seed[i]
  }
  let block = FixedArray::make(16384, b'\x00')
  let (size, _, _) = compress_block_from_sequences(
    sequences,
    literals,
    0,
    literals.length(),
    block,
    None,
    None,
  )
  let original_buf = @blit.Buffer::new()
  let mut lit_pos = 0
  for seq in sequences {
    for _ in 0..<seq.lit_len {
      original_buf.write_byte(literals[lit_pos])
      lit_pos += 1
    }
    let actual_offset = seq.offset - 3
    let base_len = original_buf.length()
    for j in 0..<seq.match_len {
      original_buf.write_byte(
        original_buf.get_byte(base_len - actual_offset + j),
      )
    }
  }
  let original = original_buf.to_bytes()
  let block_bytes = fixed_array_prefix_to_bytes(block, size)
  let (lit_data, lit_pos, _) = decode_literals_section(
    block_bytes[:],
    0,
    size,
    None,
  )
  assert_eq(lit_data, Bytes::makei(literals.length(), fn(i) { literals[i] }))
  let num_seq = decode_num_sequences(block_bytes[:], lit_pos, size)
  let seq_pos = lit_pos +
    num_sequence_header_bytes(block_bytes[:], lit_pos, size)
  let modes = block[seq_pos].to_int()
  let (seq_tables, seq_data_pos) = decode_sequence_tables(
    block_bytes[:],
    seq_pos + 1,
    size,
    modes,
    None,
  )
  let ll_codes = FixedArray::make(sequences.length(), 0)
  let of_codes = FixedArray::make(sequences.length(), 0)
  let ml_codes = FixedArray::make(sequences.length(), 0)
  for i in 0..<sequences.length() {
    let seq = sequences[i]
    let (ll_code, _, _) = get_ll_code(seq.lit_len)
    let (of_code, _, _) = get_offset_code(seq.offset)
    let (ml_code, _, _) = get_ml_code(seq.match_len)
    ll_codes[i] = ll_code
    of_codes[i] = of_code
    ml_codes[i] = ml_code
  }
  let ll_choice = select_sequence_encoder(
    ll_codes,
    ll_codes.length(),
    35,
    SeqDecoder::Fse(ll_default_table),
    ll_default_norm,
    LL_DEFAULT_ACCURACY,
    None,
  )
  let of_choice = select_sequence_encoder(
    of_codes,
    of_codes.length(),
    28,
    SeqDecoder::Fse(of_default_table),
    of_default_norm,
    OF_DEFAULT_ACCURACY,
    None,
  )
  match of_choice.header {
    Some(header) =>
      match build_fse_table_from_description(header[:], 31, 8) {
        (table, bytes_read) => {
          assert_eq(bytes_read, header.length())
          assert_true(
            seq_decoder_eq(SeqDecoder::Fse(table), of_choice.next_decoder),
          )
        }
      }
    None => ()
  }
  let ml_choice = select_sequence_encoder(
    ml_codes,
    ml_codes.length(),
    52,
    SeqDecoder::Fse(ml_default_table),
    ml_default_norm,
    ML_DEFAULT_ACCURACY,
    None,
  )
  assert_eq((modes >> 6) & 0x03, ll_choice.mode)
  assert_eq((modes >> 4) & 0x03, of_choice.mode)
  assert_eq((modes >> 2) & 0x03, ml_choice.mode)
  assert_true(seq_decoder_eq(seq_tables.ll, ll_choice.next_decoder))
  assert_true(seq_decoder_eq(seq_tables.of, of_choice.next_decoder))
  assert_true(seq_decoder_eq(seq_tables.ml, ml_choice.next_decoder))
  assert_eq(num_seq, sequences.length())
  assert_eq(
    execute_sequences(
      lit_data,
      num_seq,
      block_bytes[seq_data_pos:size],
      seq_tables,
      @blit.Buffer::new(),
      b""[:],
      [1, 4, 8],
      1 << 20,
    ),
    original,
  )
  let frame = FixedArray::make(size + 32, b'\x00')
  let mut pos = write_zstd_frame_header(frame, 0, original.length(), 0U)
  pos = write_block_header_fixed(frame, pos, true, BLOCK_TYPE_COMPRESSED, size)
  for i in 0..<size {
    frame[pos + i] = block[i]
  }
  pos += size
  let xxh = @checksum.XXH64::new()
  xxh.update(original[:])
  let checksum = xxh.checksum64().to_uint()
  frame[pos] = (checksum & 0xFFU).to_byte()
  frame[pos + 1] = ((checksum >> 8) & 0xFFU).to_byte()
  frame[pos + 2] = ((checksum >> 16) & 0xFFU).to_byte()
  frame[pos + 3] = ((checksum >> 24) & 0xFFU).to_byte()
  pos += 4
  let compressed = Bytes::makei(pos, fn(i) { frame[i] })
  assert_eq(decompress(compressed), original)
}

///|
test "custom sequence bitstreams round-trip through execute_sequences" {
  let sequences : Array[ZstdSequence] = [
    { lit_len: 16, offset: 19, match_len: 16, actual_offset: 16 },
  ]
  for i in 0..<1023 {
    if i < 895 {
      sequences.push({
        lit_len: 0,
        offset: 19,
        match_len: 16,
        actual_offset: 16,
      })
    } else {
      sequences.push({ lit_len: 1, offset: 11, match_len: 8, actual_offset: 8 })
    }
  }
  let literals = FixedArray::make(144, b'q')
  let seed = b"abcdefghijklmnop"
  for i in 0..<seed.length() {
    literals[i] = seed[i]
  }
  let ll_codes = FixedArray::make(sequences.length(), 0)
  let of_codes = FixedArray::make(sequences.length(), 0)
  let ml_codes = FixedArray::make(sequences.length(), 0)
  for i in 0..<sequences.length() {
    let seq = sequences[i]
    let (ll_code, _, _) = get_ll_code(seq.lit_len)
    let (of_code, _, _) = get_offset_code(seq.offset)
    let (ml_code, _, _) = get_ml_code(seq.match_len)
    ll_codes[i] = ll_code
    of_codes[i] = of_code
    ml_codes[i] = ml_code
  }
  let ll_plan = build_custom_fse_plan(ll_codes, ll_codes.length(), 35, 9)
  let of_plan = build_custom_fse_plan(of_codes, of_codes.length(), 28, 8)
  let ml_plan = build_custom_fse_plan(ml_codes, ml_codes.length(), 52, 9)
  let temp = FixedArray::make(16384, b'\x00')
  match (ll_plan, of_plan, ml_plan) {
    (Some(ll_plan), Some(of_plan), Some(ml_plan)) => {
      let size = encode_sequences(
        sequences,
        ll_codes,
        of_codes,
        ml_codes,
        Some(
          build_fse_ctable(
            ll_plan.norm_counts,
            ll_plan.actual_max_symbol,
            ll_plan.table_log,
          ),
        ),
        None,
        Some(
          build_fse_ctable(
            of_plan.norm_counts,
            of_plan.actual_max_symbol,
            of_plan.table_log,
          ),
        ),
        None,
        Some(
          build_fse_ctable(
            ml_plan.norm_counts,
            ml_plan.actual_max_symbol,
            ml_plan.table_log,
          ),
        ),
        None,
        temp,
        0,
      )
      let encoded = Bytes::makei(size, fn(i) { temp[i] })
      let decoded = execute_sequences(
        Bytes::makei(literals.length(), fn(i) { literals[i] }),
        sequences.length(),
        encoded[:],
        {
          ll: SeqDecoder::Fse(
            FseTable::build(
              ll_plan.norm_counts,
              ll_plan.actual_max_symbol,
              ll_plan.table_log,
            ),
          ),
          of: SeqDecoder::Fse(
            FseTable::build(
              of_plan.norm_counts,
              of_plan.actual_max_symbol,
              of_plan.table_log,
            ),
          ),
          ml: SeqDecoder::Fse(
            FseTable::build(
              ml_plan.norm_counts,
              ml_plan.actual_max_symbol,
              ml_plan.table_log,
            ),
          ),
        },
        @blit.Buffer::new(),
        b""[:],
        [1, 4, 8],
        1 << 20,
      )
      let original_buf = @blit.Buffer::new()
      let mut lit_pos = 0
      for seq in sequences {
        for _ in 0..<seq.lit_len {
          original_buf.write_byte(literals[lit_pos])
          lit_pos += 1
        }
        let actual_offset = seq.offset - 3
        let base_len = original_buf.length()
        for j in 0..<seq.match_len {
          original_buf.write_byte(
            original_buf.get_byte(base_len - actual_offset + j),
          )
        }
      }
      assert_eq(decoded, original_buf.to_bytes())
    }
    _ => fail("expected all custom sequence plans")
  }
}

///|
test "selected sequence encoders round-trip through execute_sequences" {
  let sequences : Array[ZstdSequence] = [
    { lit_len: 16, offset: 19, match_len: 16, actual_offset: 16 },
  ]
  for i in 0..<1023 {
    if i < 895 {
      sequences.push({
        lit_len: 0,
        offset: 19,
        match_len: 16,
        actual_offset: 16,
      })
    } else {
      sequences.push({ lit_len: 1, offset: 11, match_len: 8, actual_offset: 8 })
    }
  }
  let literals = FixedArray::make(144, b'q')
  let seed = b"abcdefghijklmnop"
  for i in 0..<seed.length() {
    literals[i] = seed[i]
  }
  let ll_codes = FixedArray::make(sequences.length(), 0)
  let of_codes = FixedArray::make(sequences.length(), 0)
  let ml_codes = FixedArray::make(sequences.length(), 0)
  for i in 0..<sequences.length() {
    let seq = sequences[i]
    let (ll_code, _, _) = get_ll_code(seq.lit_len)
    let (of_code, _, _) = get_offset_code(seq.offset)
    let (ml_code, _, _) = get_ml_code(seq.match_len)
    ll_codes[i] = ll_code
    of_codes[i] = of_code
    ml_codes[i] = ml_code
  }
  let ll_choice = select_sequence_encoder(
    ll_codes,
    ll_codes.length(),
    35,
    SeqDecoder::Fse(ll_default_table),
    ll_default_norm,
    LL_DEFAULT_ACCURACY,
    None,
  )
  let of_choice = select_sequence_encoder(
    of_codes,
    of_codes.length(),
    28,
    SeqDecoder::Fse(of_default_table),
    of_default_norm,
    OF_DEFAULT_ACCURACY,
    None,
  )
  let ml_choice = select_sequence_encoder(
    ml_codes,
    ml_codes.length(),
    52,
    SeqDecoder::Fse(ml_default_table),
    ml_default_norm,
    ML_DEFAULT_ACCURACY,
    None,
  )
  let temp = FixedArray::make(16384, b'\x00')
  let size = encode_sequences(
    sequences,
    ll_codes,
    of_codes,
    ml_codes,
    ll_choice.ctable,
    ll_choice.rle_symbol,
    of_choice.ctable,
    of_choice.rle_symbol,
    ml_choice.ctable,
    ml_choice.rle_symbol,
    temp,
    0,
  )
  let encoded = Bytes::makei(size, fn(i) { temp[i] })
  let decoded = execute_sequences(
    Bytes::makei(literals.length(), fn(i) { literals[i] }),
    sequences.length(),
    encoded[:],
    {
      ll: ll_choice.next_decoder,
      of: of_choice.next_decoder,
      ml: ml_choice.next_decoder,
    },
    @blit.Buffer::new(),
    b""[:],
    [1, 4, 8],
    1 << 20,
  )
  let original_buf = @blit.Buffer::new()
  let mut lit_pos = 0
  for seq in sequences {
    for _ in 0..<seq.lit_len {
      original_buf.write_byte(literals[lit_pos])
      lit_pos += 1
    }
    let actual_offset = seq.offset - 3
    let base_len = original_buf.length()
    for j in 0..<seq.match_len {
      original_buf.write_byte(
        original_buf.get_byte(base_len - actual_offset + j),
      )
    }
  }
  assert_eq(decoded, original_buf.to_bytes())
}

///|
test "literal-only blocks can emit custom Huffman literals" {
  let pattern = b"aaaaabbbbcccddeeffgghhii jjkkllmmnnooppqqrrssttuu"
  let literals = FixedArray::makei(320, fn(i) { pattern[i % pattern.length()] })
  let block = FixedArray::make(2048, b'\x00')
  let (size, next_lit, _) = compress_literal_only_block(
    literals,
    0,
    literals.length(),
    block,
    None,
    None,
  )
  assert_true(size > 0)
  assert_eq(block[0].to_int() & 0x03, 2)
  match next_lit {
    Some(_) => ()
    None => fail("expected literal table to be preserved for repeat mode")
  }
}

///|
test "literal-only blocks can emit treeless literals" {
  let weights = [1]
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
}

///|
fn seq_decoder_eq(actual : SeqDecoder, expected : SeqDecoder) -> Bool {
  match (actual, expected) {
    (SeqDecoder::Rle(lhs), SeqDecoder::Rle(rhs)) => lhs == rhs
    (SeqDecoder::Fse(lhs), SeqDecoder::Fse(rhs)) => {
      if lhs._accuracy_log != rhs._accuracy_log ||
        lhs.symbols.length() != rhs.symbols.length() {
        return false
      }
      for i in 0..<lhs.symbols.length() {
        if lhs.symbols[i] != rhs.symbols[i] {
          return false
        }
      }
      for i in 0..<lhs.num_bits.length() {
        if lhs.num_bits[i] != rhs.num_bits[i] ||
          lhs.new_state_base[i] != rhs.new_state_base[i] {
          return false
        }
      }
      true
    }
    _ => false
  }
}
