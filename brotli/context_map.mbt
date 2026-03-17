///|
pub(all) enum ContextMode {
  LSB6
  MSB6
  UTF8
  Signed
} derive(Eq, Show)

///|
fn context_mode_from_bits(bits : Int) -> ContextMode raise BrotliError {
  match bits {
    0 => LSB6
    1 => MSB6
    2 => UTF8
    3 => Signed
    _ => raise BrotliError::CorruptInput("invalid literal context mode")
  }
}

///|
fn literal_context_lookup_base(mode : ContextMode) -> Int {
  match mode {
    LSB6 => 0
    MSB6 => 512
    UTF8 => 1024
    Signed => 1536
  }
}

///|
fn literal_context_id(mode : ContextMode, p1 : Byte, p2 : Byte) -> Int {
  let base = literal_context_lookup_base(mode)
  literal_context_lookup(base + p1.to_int()).to_int() |
  literal_context_lookup(base + 256 + p2.to_int()).to_int()
}

///|
fn inverse_move_to_front_in_place(values : FixedArray[Byte], len : Int) -> Unit {
  let mtf = FixedArray::make(256, b'\x00')
  for i in 0..<256 {
    mtf[i] = i.to_byte()
  }
  for i in 0..<len {
    let index = values[i].to_int()
    let value = mtf[index]
    values[i] = value
    let mut current = index
    while current > 0 {
      mtf[current] = mtf[current - 1]
      current -= 1
    }
    mtf[0] = value
  }
}

///|
fn read_rle_max(reader : BitReader) -> Int raise BrotliError {
  let first = reader.read_required(1)
  if first == 0 {
    return 0
  }
  reader.read_required(4) + 1
}

///|
fn decode_context_map(
  reader : BitReader,
  context_map_size : Int,
  num_trees : Int,
) -> Bytes raise BrotliError {
  let result = FixedArray::make(context_map_size, b'\x00')
  if num_trees <= 1 {
    return result.unsafe_reinterpret_as_bytes()
  }
  let rle_max = read_rle_max(reader)
  let decoder = read_prefix_code(reader, num_trees + rle_max)
  let mut index = 0
  while index < context_map_size {
    let symbol = match decoder.decode(reader) {
      Some(value) => value
      None => raise BrotliError::UnexpectedEOF
    }
    if symbol == 0 {
      result[index] = 0
      index += 1
      continue
    }
    if symbol <= rle_max {
      let reps = (1 << symbol) + reader.read_required(symbol)
      guard index + reps <= context_map_size else {
        raise BrotliError::CorruptInput("context map repeat exceeds size")
      }
      for i in 0..<reps {
        result[index + i] = 0
      }
      index += reps
      continue
    }
    let value = symbol - rle_max
    guard value < num_trees else {
      raise BrotliError::CorruptInput("context map tree index out of range")
    }
    result[index] = value.to_byte()
    index += 1
  }
  if reader.read_required(1) != 0 {
    inverse_move_to_front_in_place(result, context_map_size)
  }
  result.unsafe_reinterpret_as_bytes()
}
