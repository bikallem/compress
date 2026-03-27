///|
priv struct ZstdDictionary {
  content : Bytes
  dict_id : UInt
  rep : Array[Int]
  lit_table : ZstdHuffmanTable?
  seq_tables : SeqTables?
}

///|
priv struct ZstdDictionarySet {
  raws : Array[ZstdDictionary]
  reuse_single_raw : Bool
  formatted : Array[ZstdDictionary]
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
fn raw_dictionary(dict : Bytes) -> ZstdDictionary {
  {
    content: dict,
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
fn parse_dictionary_for_single_decode(
  dict : Bytes,
) -> ZstdDictionary raise ZstdError {
  if dict.length() == 0 {
    return empty_dictionary()
  }
  if dict.length() < 8 {
    return raw_dictionary(dict)
  }
  let src = dict[:]
  let magic = read_u32_le(src, 0)
  if magic != 0xEC30A437_U {
    return raw_dictionary(dict)
  }
  parse_formatted_dictionary_bytes(dict)
}

///|
fn empty_dictionary_set() -> ZstdDictionarySet {
  { raws: [], reuse_single_raw: true, formatted: [] }
}

///|
fn parse_formatted_dictionary_bytes(
  dict : Bytes,
) -> ZstdDictionary raise ZstdError {
  let src = dict[:]
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
fn parse_dictionary_for_encoder(dict : Bytes) -> ZstdDictionary raise ZstdError {
  if dict.length() == 0 {
    return empty_dictionary()
  }
  if dict.length() < 8 {
    return raw_dictionary(dict)
  }
  let src = dict[:]
  let magic = read_u32_le(src, 0)
  if magic != 0xEC30A437_U {
    return raw_dictionary(dict)
  }
  parse_formatted_dictionary_bytes(dict)
}

///|
fn single_dictionary_set(dict : Bytes) -> ZstdDictionarySet raise ZstdError {
  if dict.length() == 0 {
    return empty_dictionary_set()
  }
  let parsed = parse_dictionary_for_single_decode(dict)
  if parsed.dict_id == 0U {
    { raws: [parsed], reuse_single_raw: true, formatted: [] }
  } else {
    { raws: [], reuse_single_raw: true, formatted: [parsed] }
  }
}

///|
fn parse_dictionary_for_registry(
  dict : Bytes,
) -> ZstdDictionary raise ZstdError {
  if dict.length() == 0 {
    return empty_dictionary()
  }
  if dict.length() < 8 {
    return raw_dictionary(dict)
  }
  let src = dict[:]
  let magic = read_u32_le(src, 0)
  if magic != 0xEC30A437_U {
    return raw_dictionary(dict)
  }
  parse_formatted_dictionary_bytes(dict)
}

///|
fn build_dictionary_set(
  dicts : Array[Bytes],
) -> ZstdDictionarySet raise ZstdError {
  let raws : Array[ZstdDictionary] = []
  let formatted : Array[ZstdDictionary] = []
  for dict in dicts {
    let parsed = parse_dictionary_for_registry(dict)
    if parsed.dict_id == 0U {
      raws.push(parsed)
      continue
    }
    for existing in formatted {
      if existing.dict_id == parsed.dict_id {
        raise ZstdError::InvalidHeader("duplicate formatted dictionary id")
      }
    }
    formatted.push(parsed)
  }
  let reuse_single_raw = raws.length() == 1 &&
    raws.unsafe_get(0).content.length() > 0
  { raws, reuse_single_raw, formatted }
}

///|
fn select_frame_dictionary(
  dicts : ZstdDictionarySet,
  dict_id : UInt,
  raw_idx : Int,
) -> (ZstdDictionary, Int) raise ZstdError {
  if dict_id == 0U {
    if dicts.raws.length() == 0 {
      return (empty_dictionary(), raw_idx)
    }
    if dicts.reuse_single_raw {
      return (dicts.raws.unsafe_get(0), raw_idx)
    }
    if raw_idx < dicts.raws.length() {
      return (dicts.raws.unsafe_get(raw_idx), raw_idx + 1)
    }
    raise ZstdError::InvalidHeader("raw dictionary registry exhausted")
  }
  for dict in dicts.formatted {
    if dict.dict_id == dict_id {
      return (dict, raw_idx)
    }
  }
  raise ZstdError::InvalidHeader(
    "dictionary id \{dict_id} requires matching formatted dictionary",
  )
}
