///|
test "brotli hash uses unsigned little-endian words" {
  let data : Bytes = b"\xff\x80\xaa\xcc\x11"
  let raw = data[0].to_uint() |
    (data[1].to_uint() << 8) |
    (data[2].to_uint() << 16) |
    (data[3].to_uint() << 24)
  let mixed = (raw & 0xFFFFFFU) ^ (((raw >> 16) & 0xFFU) * 0x1e35a7bdU)
  let expected = mixed.reinterpret_as_int() & (BROTLI_HASH_SIZE - 1)
  assert_eq(brotli_hash4(data[:], 0), expected)
}

///|
test "brotli identity dictionary matches common words" {
  let (length, distance) = find_identity_dictionary_match(
    b"function"[:],
    0,
    8,
    0,
  )
  assert_eq(length, 8)
  assert_true(distance > 0)
}

///|
test "brotli transformed dictionary matches affixed and uppercased words" {
  let (length, copy_len, distance) = find_transformed_dictionary_match(
    b" Function "[:],
    0,
    10,
    0,
    0,
  )
  assert_eq(length, 10)
  assert_eq(copy_len, 8)
  assert_true(distance > 0)
}

///|
test "brotli transformed dictionary matches omitted prefixes and suffixes" {
  let (omit_last_len, omit_last_copy_len, omit_last_distance) = find_transformed_dictionary_match(
    b"functio"[:],
    0,
    7,
    0,
    0,
  )
  assert_eq(omit_last_len, 7)
  assert_eq(omit_last_copy_len, 8)
  assert_true(omit_last_distance > 0)

  let (omit_first_len, omit_first_copy_len, omit_first_distance) = find_transformed_dictionary_match(
    b"unction"[:],
    0,
    7,
    0,
    0,
  )
  assert_eq(omit_first_len, 7)
  assert_eq(omit_first_copy_len, 8)
  assert_true(omit_first_distance > 0)
}

///|
priv struct BrotliTransformFixture {
  out : Bytes
}

///|
fn brotli_transform_fixture(transform_idx : Int) -> BrotliTransformFixture? {
  for length in dict_min_word_length..<=dict_max_word_length {
    let shift = dict_size_bits_by_length[length]
    if shift <= 0 {
      continue
    }
    let count = 1 << shift
    for word_idx in 0..<count {
      let offset = dict_word_offset(length, word_idx)
      let tmp = FixedArray::make(length + 16, b'\x00')
      let out_len = transform_dictionary_word(
        tmp, 0, brotli_dictionary_data, offset, length, transform_idx,
      )
      if out_len >= 4 {
        let out = Bytes::makei(out_len, fn(i) { tmp[i] })
        return Some({ out, })
      }
    }
  }
  None
}

///|
test "brotli transformed dictionary search covers all transform ids" {
  for transform_idx in 1..<121 {
    match brotli_transform_fixture(transform_idx) {
      Some(fixture) => {
        let (length, copy_len, distance) = find_transformed_dictionary_match(
          fixture.out[:],
          0,
          fixture.out.length(),
          0,
          0,
        )
        assert_eq(length, fixture.out.length())
        assert_true(copy_len >= 4)
        assert_true(distance > 0)
      }
      None => fail("expected Brotli transform fixture")
    }
  }
}

///|
fn brotli_split_fixture() -> Bytes {
  let buf = @blit.Buffer::new()
  for i in 0..<128 {
    buf.write_bytes(
      b"function return value status code request header response payload\n",
    )
    for j in 0..<256 {
      buf.write_byte(((i * 17 + j * 31) % 251).to_byte())
    }
    buf.write_bytes(
      b"The quick brown fox jumps over the lazy dog. This log segment is highly compressible.\n",
    )
  }
  buf.to_bytes()
}

///|
test "brotli split candidate can beat a single metablock" {
  let data = brotli_split_fixture()
  let split = compress_lz77_split(data[:], data.length(), 11, 16384)
  let wbits = optimal_wbits(data.length())
  let cmds = lz77_find_matches_chain(data[:], data.length(), 11)
  let single = encode_compressed_metablock(
    data[:],
    data.length(),
    cmds,
    11,
    wbits,
  )
  assert_eq(decompress(split), data)
  assert_eq(decompress(single), data)
  assert_true(split.length() <= single.length())
}

///|
fn brotli_chunked_tuning_fixture() -> Bytes {
  let buf = @blit.Buffer::new()
  for i in 0..<150 {
    buf.write_bytes(
      b"function return value status code request header response payload authorization accept-language cache-control x-request-id content-type transfer-encoding if-none-match\n",
    )
    buf.write_byte((i % 251).to_byte())
    buf.write_bytes(b"\n")
  }
  for i in 0..<150 {
    buf.write_bytes(
      b"<div class=\"content\"><span class=\"title\">render component layout container flex justify-center items-start border rounded shadow-sm bg-slate-100</span><a href=\"https://example.com/docs/index.html\">docs</a></div>\n",
    )
    buf.write_byte((i * 17 % 251).to_byte())
    buf.write_bytes(b"\n")
  }
  for i in 0..<150 {
    buf.write_bytes(
      b"{\"status\":\"ok\",\"message\":\"stream update applied\",\"request_id\":\"abc123\",\"payload\":{\"items\":[1,2,3,4],\"feature\":\"brotli\",\"retry_after\":0,\"accepted\":true}}\n",
    )
    buf.write_byte((i * 31 % 251).to_byte())
    buf.write_bytes(b"\n")
  }
  for i in 0..<150 {
    buf.write_bytes(
      b".layout-grid{display:grid;grid-template-columns:repeat(12,minmax(0,1fr));gap:1rem;padding:1.5rem;background:linear-gradient(90deg,#eee,#ddd);font-weight:600;letter-spacing:.02em}\n",
    )
    buf.write_byte((i * 47 % 251).to_byte())
    buf.write_bytes(b"\n")
  }
  buf.to_bytes()
}

///|
test "brotli chunked encoder preserves higher-level tuning" {
  let data = brotli_chunked_tuning_fixture()
  let level1 = compress_lz77_chunked(data[:], data.length(), 1)
  let level11 = compress_lz77_chunked(data[:], data.length(), 11)
  assert_eq(decompress(level1), data)
  assert_eq(decompress(level11), data)
  assert_true(level11.length() < level1.length())
}

///|
fn brotli_mid_split_fixture() -> Bytes {
  let buf = @blit.Buffer::new()
  let alpha1 = b"abcdef"
  let alpha2 = b"UVWXYZ"
  let alpha3 = b"012345{}[],:;"
  for i in 0..<32768 {
    let idx = (i * 17 + i / 7) % alpha1.length()
    buf.write_byte(alpha1[idx])
  }
  for i in 0..<32768 {
    let idx = (i * 19 + i / 11) % alpha2.length()
    buf.write_byte(alpha2[idx])
  }
  for i in 0..<32768 {
    let idx = (i * 23 + i / 13) % alpha3.length()
    buf.write_byte(alpha3[idx])
  }
  buf.to_bytes()
}

///|
test "brotli adaptive split candidates improve mid-sized heterogeneous input" {
  let data = brotli_mid_split_fixture()
  let compressed = compress(data, level=Best)
  let split16 = compress_lz77_split(data[:], data.length(), 11, 16384)
  let split48 = compress_lz77_split(data[:], data.length(), 11, 49152)
  assert_eq(decompress(compressed), data)
  assert_true(split48.length() < split16.length())
  assert_true(compressed.length() <= split48.length())
}
