///|
let min_dictionary_word_length : Int = 4

///|
let max_dictionary_word_length : Int = 24

///|
let transform_identity : Int = 0

///|
let transform_omit_last_1 : Int = 1

///|
let transform_omit_last_9 : Int = 9

///|
let transform_ferment_first : Int = 10

///|
let transform_ferment_all : Int = 11

///|
let transform_omit_first_1 : Int = 12

///|
let transform_omit_first_9 : Int = 20

///|
fn dictionary_word_count(length : Int) -> Int {
  if length < min_dictionary_word_length || length > max_dictionary_word_length {
    0
  } else {
    1 << static_dictionary_size_bits(length)
  }
}

///|
fn static_dictionary_word(length : Int, index : Int) -> Bytes raise BrotliError {
  let count = dictionary_word_count(length)
  guard count > 0 else {
    raise BrotliError::CorruptInput("invalid dictionary word length")
  }
  guard index >= 0 && index < count else {
    raise BrotliError::CorruptInput("dictionary word index out of range")
  }
  let dict = static_dictionary_bytes()
  let start = static_dictionary_word_offset(length) + index * length
  Bytes::makei(length, fn(i) { dict[start + i] })
}

///|
fn ferment_step(word : FixedArray[Byte], offset : Int, len : Int) -> Int {
  let lead = word[offset].to_int()
  if lead < 0xC0 {
    if lead >= 97 && lead <= 122 {
      word[offset] = (lead ^ 32).to_byte()
    }
    return 1
  }
  if lead < 0xE0 {
    if len > 1 {
      word[offset + 1] = (word[offset + 1].to_int() ^ 32).to_byte()
    }
    return 2
  }
  if len > 2 {
    word[offset + 2] = (word[offset + 2].to_int() ^ 5).to_byte()
  }
  3
}

///|
fn transform_affix_bytes(id : Int) -> Bytes raise BrotliError {
  guard id >= 0 && id < transform_prefix_suffix_map.length() else {
    raise BrotliError::CorruptInput("invalid transform affix id")
  }
  let start = transform_prefix_suffix_offset(id)
  let data = transform_prefix_suffix_bytes()
  if start == data.length() {
    return Bytes::default()
  }
  guard start >= 0 && start < data.length() else {
    raise BrotliError::CorruptInput("invalid transform affix offset")
  }
  let len = data[start].to_int()
  Bytes::makei(len, fn(i) { data[start + 1 + i] })
}

///|
fn transform_word(
  word : BytesView,
  transform_id : Int,
) -> Bytes raise BrotliError {
  guard transform_id >= 0 && transform_id < transform_count() else {
    raise BrotliError::CorruptInput("invalid transform id")
  }
  let triplet_index = transform_id * 3
  let prefix = transform_affix_bytes(transform_triplet_value(triplet_index))
  let transform = transform_triplet_value(triplet_index + 1)
  let suffix = transform_affix_bytes(transform_triplet_value(triplet_index + 2))

  let word_len = word.length()
  let start = if transform >= transform_omit_first_1 &&
    transform <= transform_omit_first_9 {
    let omit = transform - transform_omit_first_1 + 1
    if omit < word_len {
      omit
    } else {
      word_len
    }
  } else {
    0
  }
  let end = if transform >= transform_omit_last_1 &&
    transform <= transform_omit_last_9 {
    let omit = transform - transform_omit_last_1 + 1
    if omit < word_len {
      word_len - omit
    } else {
      0
    }
  } else {
    word_len
  }
  let base_len = if end > start { end - start } else { 0 }
  let total_len = prefix.length() + base_len + suffix.length()
  let output = FixedArray::make(total_len, b'\x00')
  let mut pos = 0
  for i, b in prefix {
    output[pos + i] = b
  }
  pos += prefix.length()
  for i in 0..<base_len {
    output[pos + i] = word[start + i]
  }
  if transform == transform_ferment_first && base_len > 0 {
    ignore(ferment_step(output, pos, base_len))
  } else if transform == transform_ferment_all {
    let mut cursor = 0
    while cursor < base_len {
      cursor += ferment_step(output, pos + cursor, base_len - cursor)
    }
  } else if transform != transform_identity &&
    (transform < transform_omit_last_1 || transform > transform_omit_first_9) {
    raise BrotliError::UnsupportedFeature("unsupported word transform")
  }
  pos += base_len
  for i, b in suffix {
    output[pos + i] = b
  }
  output.unsafe_reinterpret_as_bytes()
}

///|
fn static_dictionary_reference(
  length : Int,
  word_id : Int,
) -> Bytes raise BrotliError {
  let count = dictionary_word_count(length)
  guard count > 0 else {
    raise BrotliError::CorruptInput("invalid dictionary reference length")
  }
  guard word_id >= 0 else {
    raise BrotliError::CorruptInput("invalid dictionary word id")
  }
  let size_bits = static_dictionary_size_bits(length)
  let transform_id = word_id >> size_bits
  let index = word_id & (count - 1)
  let base = static_dictionary_word(length, index)
  transform_word(base[:], transform_id)
}
