///|
priv struct ZstdDictionary {
  content : Bytes
  dict_id : UInt
  rep : Array[Int]
  lit_table : ZstdHuffmanTable?
  seq_tables : SeqTables?
}

///|
fn default_rep_offsets() -> Array[Int] {
  [1, 4, 8]
}

///|
fn empty_dictionary() -> ZstdDictionary {
  {
    content: b"",
    dict_id: 0U,
    rep: default_rep_offsets(),
    lit_table: None,
    seq_tables: None,
  }
}

///|
fn copy_rep_offsets(rep : Array[Int]) -> Array[Int] {
  [rep.unsafe_get(0), rep.unsafe_get(1), rep.unsafe_get(2)]
}

///|
fn parse_dictionary_bytes(dict : Bytes) -> ZstdDictionary raise ZstdError {
  if dict.length() == 0 {
    return empty_dictionary()
  }
  guard dict.length() >= 8 else {
    raise ZstdError::InvalidHeader("zstd dictionary must be at least 8 bytes")
  }
  let src = dict[:]
  let magic = read_u32_le(src, 0)
  if magic != 0xEC30A437_U {
    return {
      content: dict,
      dict_id: 0U,
      rep: default_rep_offsets(),
      lit_table: None,
      seq_tables: None,
    }
  }
  let dict_id = read_u32_le(src, 4)
  guard dict_id != 0U else {
    raise ZstdError::InvalidHeader("formatted zstd dictionary id cannot be 0")
  }
  let mut pos = 8
  let (lit_table, lit_bytes) = ZstdHuffmanTable::from_description(src[pos:])
  pos += lit_bytes
  let (of_table, of_bytes) = build_fse_table_from_description(src[pos:], 31, 8)
  pos += of_bytes
  let (ml_table, ml_bytes) = build_fse_table_from_description(src[pos:], 52, 9)
  pos += ml_bytes
  let (ll_table, ll_bytes) = build_fse_table_from_description(src[pos:], 35, 9)
  pos += ll_bytes
  guard pos + 12 <= dict.length() else { raise ZstdError::UnexpectedEOF }
  let rep0 = read_u32_le(src, pos).reinterpret_as_int()
  let rep1 = read_u32_le(src, pos + 4).reinterpret_as_int()
  let rep2 = read_u32_le(src, pos + 8).reinterpret_as_int()
  pos += 12
  let content = Bytes::makei(dict.length() - pos, fn(i) {
    src.unsafe_get(pos + i)
  })
  let content_len = content.length()
  guard content_len >= 8 else {
    raise ZstdError::InvalidHeader(
      "formatted zstd dictionary content must be at least 8 bytes",
    )
  }
  for rep in [rep0, rep1, rep2] {
    guard rep > 0 && rep <= content_len else {
      raise ZstdError::CorruptData("dictionary repeat offset exceeds content")
    }
  }
  {
    content,
    dict_id,
    rep: [rep0, rep1, rep2],
    lit_table: Some(lit_table),
    seq_tables: Some({
      ll: SeqDecoder::Fse(ll_table),
      of: SeqDecoder::Fse(of_table),
      ml: SeqDecoder::Fse(ml_table),
    }),
  }
}

///|
fn parse_dictionary_for_encoder(dict : Bytes) -> ZstdDictionary {
  let parsed = try? parse_dictionary_bytes(dict)
  match parsed {
    Ok(parsed) => parsed
    Err(_) =>
      if dict.length() >= 8 {
        {
          content: dict,
          dict_id: 0U,
          rep: default_rep_offsets(),
          lit_table: None,
          seq_tables: None,
        }
      } else {
        empty_dictionary()
      }
  }
}
