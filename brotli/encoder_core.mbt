///|
priv struct InsertOnlyCommand {
  symbol : Int
  extra_bits : Int
  extra_value : Int
}

///|
priv enum BlockPlan {
  Literal(Int, Int)
  Run(Byte, Int)
}

///|
priv struct CopyCommand {
  symbol : Int
  insert_extra_bits : Int
  insert_extra_value : Int
  copy_extra_bits : Int
  copy_extra_value : Int
}

///|
fn store_var_len_uint8(
  writer : BitWriter,
  value : Int,
) -> Unit raise BrotliError {
  guard value >= 0 && value <= 255 else {
    raise BrotliError::CorruptInput("invalid var-len uint8 value")
  }
  if value == 0 {
    writer.write_bits(0U, 1)
    return
  }
  let nbits = log2_floor_plus_one(value) - 1
  writer.write_bits(1U, 1)
  writer.write_bits(nbits.reinterpret_as_uint(), 3)
  writer.write_bits((value - (1 << nbits)).reinterpret_as_uint(), nbits)
}

///|
fn write_compressed_meta_block_header(
  writer : BitWriter,
  is_last : Bool,
  length : Int,
) -> Unit raise BrotliError {
  writer.write_bits((if is_last { 1 } else { 0 }).reinterpret_as_uint(), 1)
  if is_last {
    writer.write_bits(0U, 1)
  }
  write_meta_block_length(writer, length)
  if !is_last {
    writer.write_bits(0U, 1)
  }
}

///|
fn write_single_symbol_prefix_tree(
  writer : BitWriter,
  symbol : Int,
  alphabet_size : Int,
) -> Unit raise BrotliError {
  let bits = alphabet_bits(alphabet_size)
  guard symbol >= 0 && symbol < alphabet_size else {
    raise BrotliError::CorruptInput("prefix-tree symbol out of range")
  }
  writer.write_bits(1U, 4)
  writer.write_bits(symbol.reinterpret_as_uint(), bits)
}

///|
fn write_code_length_code(
  writer : BitWriter,
  value : Int,
) -> Unit raise BrotliError {
  match value {
    0 => writer.write_bits(0U, 2)
    1 => writer.write_bits(7U, 4)
    2 => writer.write_bits(3U, 3)
    3 => writer.write_bits(2U, 2)
    4 => writer.write_bits(1U, 2)
    5 => writer.write_bits(15U, 4)
    _ => raise BrotliError::CorruptInput("invalid code-length code")
  }
}

///|
fn write_fixed_literal_tree(writer : BitWriter) -> Unit raise BrotliError {
  writer.write_bits(3U, 2)
  for _ in 0..<5 {
    write_code_length_code(writer, 0)
  }
  write_code_length_code(writer, 1)
  for _ in 0..<9 {
    write_code_length_code(writer, 0)
  }
  writer.write_bits(2U, 2)
  writer.write_bits(2U, 2)
  writer.write_bits(2U, 2)
  writer.write_bits(1U, 2)
}

///|
fn write_fixed_literal(writer : BitWriter, literal : Byte) -> Unit {
  writer.write_bits(reverse_bits(literal.to_int(), 8).reinterpret_as_uint(), 8)
}

///|
fn select_insert_only_command(
  length : Int,
) -> InsertOnlyCommand raise BrotliError {
  let mut best : InsertOnlyCommand? = None
  for symbol in 0..<brotli_num_command_symbols {
    if command_copy_extra_bits(symbol) != 0 {
      continue
    }
    let extra_bits = command_insert_extra_bits(symbol)
    let base = command_insert_offset(symbol)
    let span = if extra_bits == 24 { 1 << 24 } else { 1 << extra_bits }
    if length < base || length >= base + span {
      continue
    }
    let candidate = { symbol, extra_bits, extra_value: length - base }
    best = match best {
      None => Some(candidate)
      Some(current) =>
        if extra_bits < current.extra_bits {
          Some(candidate)
        } else {
          Some(current)
        }
    }
  }
  match best {
    Some(value) => value
    None =>
      raise BrotliError::UnsupportedFeature("no insert-only command for length")
  }
}

///|
fn write_trivial_prefix_metadata(writer : BitWriter) -> Unit raise BrotliError {
  store_var_len_uint8(writer, 0)
  store_var_len_uint8(writer, 0)
  store_var_len_uint8(writer, 0)
  writer.write_bits(0U, 6)
  writer.write_bits(0U, 2)
  store_var_len_uint8(writer, 0)
  store_var_len_uint8(writer, 0)
}

///|
fn write_copy_command_extra(writer : BitWriter, command : CopyCommand) -> Unit {
  writer.write_bits(
    command.insert_extra_value.reinterpret_as_uint(),
    command.insert_extra_bits,
  )
  writer.write_bits(
    command.copy_extra_value.reinterpret_as_uint(),
    command.copy_extra_bits,
  )
}

///|
fn select_copy_command(
  insert_length : Int,
  copy_length : Int,
  require_explicit_distance : Bool,
) -> CopyCommand raise BrotliError {
  let mut best : CopyCommand? = None
  for symbol in 0..<brotli_num_command_symbols {
    if require_explicit_distance && command_distance_short_code(symbol) != -1 {
      continue
    }
    let insert_extra_bits = command_insert_extra_bits(symbol)
    let insert_base = command_insert_offset(symbol)
    let copy_extra_bits = command_copy_extra_bits(symbol)
    let copy_base = command_copy_offset(symbol)
    let insert_span = if insert_extra_bits == 24 {
      1 << 24
    } else {
      1 << insert_extra_bits
    }
    let copy_span = if copy_extra_bits == 24 {
      1 << 24
    } else {
      1 << copy_extra_bits
    }
    if insert_length < insert_base || insert_length >= insert_base + insert_span {
      continue
    }
    if copy_length < copy_base || copy_length >= copy_base + copy_span {
      continue
    }
    let candidate = {
      symbol,
      insert_extra_bits,
      insert_extra_value: insert_length - insert_base,
      copy_extra_bits,
      copy_extra_value: copy_length - copy_base,
    }
    best = match best {
      None => Some(candidate)
      Some(current) =>
        if insert_extra_bits + copy_extra_bits <
          current.insert_extra_bits + current.copy_extra_bits {
          Some(candidate)
        } else {
          Some(current)
        }
    }
  }
  match best {
    Some(value) => value
    None =>
      raise BrotliError::UnsupportedFeature(
        "no command covers requested insert/copy lengths",
      )
  }
}

///|
fn write_literal_only_meta_block(
  writer : BitWriter,
  data : BytesView,
  is_last : Bool,
) -> Unit raise BrotliError {
  write_compressed_meta_block_header(writer, is_last, data.length())
  write_trivial_prefix_metadata(writer)
  write_fixed_literal_tree(writer)
  let command = select_insert_only_command(data.length())
  write_single_symbol_prefix_tree(
    writer,
    command.symbol,
    brotli_num_command_symbols,
  )
  write_single_symbol_prefix_tree(writer, 0, 64)
  writer.write_bits(
    command.extra_value.reinterpret_as_uint(),
    command.extra_bits,
  )
  for b in data {
    write_fixed_literal(writer, b)
  }
}

///|
fn write_run_meta_block(
  writer : BitWriter,
  value : Byte,
  len : Int,
  is_last : Bool,
) -> Unit raise BrotliError {
  guard len >= 2 else { raise BrotliError::CorruptInput("run block too short") }
  write_compressed_meta_block_header(writer, is_last, len)
  write_trivial_prefix_metadata(writer)
  write_single_symbol_prefix_tree(
    writer,
    value.to_int(),
    brotli_num_literal_symbols,
  )
  let command = select_copy_command(1, len - 1, true)
  write_single_symbol_prefix_tree(
    writer,
    command.symbol,
    brotli_num_command_symbols,
  )
  write_single_symbol_prefix_tree(writer, 16, 64)
  write_copy_command_extra(writer, command)
}

///|
fn append_literal_plans(
  plans : Array[BlockPlan],
  start : Int,
  len : Int,
) -> Unit {
  let mut offset = 0
  while offset < len {
    let chunk = if len - offset > max_meta_block_len {
      max_meta_block_len
    } else {
      len - offset
    }
    plans.push(Literal(start + offset, chunk))
    offset += chunk
  }
}

///|
fn append_run_plans(plans : Array[BlockPlan], value : Byte, len : Int) -> Unit {
  let mut remaining = len
  while remaining > 0 {
    let chunk = if remaining > max_meta_block_len {
      max_meta_block_len
    } else {
      remaining
    }
    plans.push(Run(value, chunk))
    remaining -= chunk
  }
}

///|
fn run_threshold(level : Int) -> Int {
  if level >= 10 {
    8
  } else if level >= 6 {
    16
  } else {
    32
  }
}

///|
fn plan_blocks(data : Bytes, level : Int) -> Array[BlockPlan] {
  let threshold = run_threshold(level)
  let plans : Array[BlockPlan] = []
  let mut literal_start = 0
  let mut pos = 0
  while pos < data.length() {
    let value = data[pos]
    let mut run_len = 1
    while pos + run_len < data.length() && data[pos + run_len] == value {
      run_len += 1
    }
    if run_len >= threshold {
      if literal_start < pos {
        append_literal_plans(plans, literal_start, pos - literal_start)
      }
      append_run_plans(plans, value, run_len)
      pos += run_len
      literal_start = pos
    } else {
      pos += 1
    }
  }
  if literal_start < data.length() {
    append_literal_plans(plans, literal_start, data.length() - literal_start)
  }
  plans
}

///|
fn compress_literal_only(data : Bytes) -> Bytes raise BrotliError {
  if data.length() == 0 {
    return trivial_compress(data)
  }
  let writer = BitWriter::new(size_hint=data.length() + 64)
  write_window_bits(writer, 16)
  let mut offset = 0
  while offset < data.length() {
    let chunk_len = if data.length() - offset > max_meta_block_len {
      max_meta_block_len
    } else {
      data.length() - offset
    }
    write_literal_only_meta_block(
      writer,
      data[offset:offset + chunk_len],
      offset + chunk_len == data.length(),
    )
    offset += chunk_len
  }
  writer.finish()
}

///|
fn compress_with_quality(data : Bytes, level : Int) -> Bytes raise BrotliError {
  if data.length() == 0 {
    return trivial_compress(data)
  }
  if level == 0 {
    return trivial_compress(data)
  }
  if level < 4 {
    return compress_literal_only(data)
  }
  let plans = plan_blocks(data, level)
  guard plans.length() > 0 else { return trivial_compress(data) }
  let writer = BitWriter::new(size_hint=data.length() + 64)
  write_window_bits(writer, 16)
  for i, plan in plans {
    let is_last = i + 1 == plans.length()
    match plan {
      Literal(start, len) =>
        write_literal_only_meta_block(writer, data[start:start + len], is_last)
      Run(value, len) => write_run_meta_block(writer, value, len, is_last)
    }
  }
  writer.finish()
}
