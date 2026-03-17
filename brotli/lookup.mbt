///|
priv struct CommandParameters {
  insert_length : Int
  copy_length : Int
  distance_context : Int
  implied_distance_code : Int?
}

///|
priv struct DistanceHistory {
  ring : FixedArray[Int]
  mut index : Int
}

///|
fn DistanceHistory::new() -> DistanceHistory {
  { ring: [16, 15, 11, 4], index: 0 }
}

///|
fn DistanceHistory::recent(self : DistanceHistory, back : Int) -> Int {
  self.ring[(self.index - back) & 3]
}

///|
fn DistanceHistory::push(self : DistanceHistory, distance : Int) -> Unit {
  self.ring[self.index & 3] = distance
  self.index += 1
}

///|
fn DistanceHistory::resolve_short_code(
  self : DistanceHistory,
  code : Int,
) -> Int raise BrotliError {
  let value = match code {
    0 => self.recent(1)
    1 => self.recent(2)
    2 => self.recent(3)
    3 => self.recent(4)
    4 => self.recent(1) - 1
    5 => self.recent(1) + 1
    6 => self.recent(1) - 2
    7 => self.recent(1) + 2
    8 => self.recent(1) - 3
    9 => self.recent(1) + 3
    10 => self.recent(2) - 1
    11 => self.recent(2) + 1
    12 => self.recent(2) - 2
    13 => self.recent(2) + 2
    14 => self.recent(2) - 3
    15 => self.recent(2) + 3
    _ => raise BrotliError::CorruptInput("invalid short distance code")
  }
  guard value > 0 else {
    raise BrotliError::CorruptInput("invalid backward distance")
  }
  value
}

///|
fn read_extra_value(extra_bits : Int, value : Int) -> Int raise BrotliError {
  guard extra_bits >= 0 && value >= 0 else {
    raise BrotliError::CorruptInput("invalid extra-bits value")
  }
  if extra_bits == 0 {
    guard value == 0 else {
      raise BrotliError::CorruptInput("extra bits must be zero")
    }
    return 0
  }
  guard value < 1 << extra_bits else {
    raise BrotliError::CorruptInput("extra bits out of range")
  }
  value
}

///|
fn block_length_value(symbol : Int, extra : Int) -> Int raise BrotliError {
  let extra_bits = block_length_prefix_extra_bits(symbol)
  block_length_prefix_offset(symbol) + read_extra_value(extra_bits, extra)
}

///|
fn command_parameters(
  symbol : Int,
  insert_extra : Int,
  copy_extra : Int,
) -> CommandParameters raise BrotliError {
  guard symbol >= 0 && symbol < 704 else {
    raise BrotliError::CorruptInput("invalid command symbol")
  }
  let insert_bits = command_insert_extra_bits(symbol)
  let copy_bits = command_copy_extra_bits(symbol)
  {
    insert_length: command_insert_offset(symbol) +
    read_extra_value(insert_bits, insert_extra),
    copy_length: command_copy_offset(symbol) +
    read_extra_value(copy_bits, copy_extra),
    distance_context: command_context(symbol),
    implied_distance_code: match command_distance_short_code(symbol) {
      -1 => None
      code => Some(code)
    },
  }
}

///|
fn distance_extra_bits(
  distance_code : Int,
  npostfix : Int,
  ndirect : Int,
) -> Int raise BrotliError {
  guard npostfix >= 0 && npostfix <= 3 else {
    raise BrotliError::CorruptInput("invalid NPOSTFIX")
  }
  guard ndirect >= 0 && ndirect <= 120 else {
    raise BrotliError::CorruptInput("invalid NDIRECT")
  }
  if distance_code < 16 + ndirect {
    return 0
  }
  1 + ((distance_code - ndirect - 16) >> (npostfix + 1))
}

///|
fn decode_distance_symbol(
  distance_code : Int,
  extra : Int,
  npostfix : Int,
  ndirect : Int,
  history : DistanceHistory,
) -> Int raise BrotliError {
  if distance_code < 16 {
    return history.resolve_short_code(distance_code)
  }
  if distance_code < 16 + ndirect {
    return distance_code - 15
  }
  let extra_bits = distance_extra_bits(distance_code, npostfix, ndirect)
  let extra_value = read_extra_value(extra_bits, extra)
  let postfix_mask = (1 << npostfix) - 1
  let hcode = (distance_code - ndirect - 16) >> npostfix
  let lcode = (distance_code - ndirect - 16) & postfix_mask
  let offset = ((2 + (hcode & 1)) << extra_bits) - 4
  let value = ((offset + extra_value) << npostfix) + lcode + ndirect + 1
  guard value > 0 else {
    raise BrotliError::CorruptInput("invalid backward distance")
  }
  value
}
