///|
let brotli_block_size_cap : Int = 1 << 24

///|
let brotli_literal_context_bits : Int = 6

///|
let brotli_distance_context_bits : Int = 2

///|
let brotli_num_literal_symbols : Int = 256

///|
let brotli_num_command_symbols : Int = 704

///|
let brotli_max_distance_bits : Int = 24

///|
priv struct StreamDecodeResult {
  output : Bytes
  remaining : Bytes
}

///|
priv struct OutputBuffer {
  mut buf : FixedArray[Byte]
  mut len : Int
}

///|
fn OutputBuffer::new(capacity : Int) -> OutputBuffer {
  let actual = if capacity < 32 { 32 } else { capacity }
  { buf: @blit.make_uninit(actual), len: 0 }
}

///|
fn OutputBuffer::length(self : OutputBuffer) -> Int {
  self.len
}

///|
fn OutputBuffer::ensure_capacity(self : OutputBuffer, additional : Int) -> Unit {
  let required = self.len + additional
  if required <= self.buf.length() {
    return
  }
  let mut new_capacity = self.buf.length() * 2
  if new_capacity < required {
    new_capacity = required
  }
  let new_buf = @blit.make_uninit(new_capacity)
  @blit.blit_fixed_array(new_buf, 0, self.buf, 0, self.len)
  self.buf = new_buf
}

///|
fn OutputBuffer::write_byte(self : OutputBuffer, b : Byte) -> Unit {
  self.ensure_capacity(1)
  self.buf.unsafe_set(self.len, b)
  self.len += 1
}

///|
fn OutputBuffer::write_bytes(self : OutputBuffer, data : Bytes) -> Unit {
  let len = data.length()
  if len == 0 {
    return
  }
  self.ensure_capacity(len)
  @blit.blit_bytes(self.buf, self.len, data, 0, len)
  self.len += len
}

///|
fn OutputBuffer::last_byte(self : OutputBuffer, back : Int) -> Byte {
  if back <= 0 || back > self.len {
    b'\x00'
  } else {
    self.buf.unsafe_get(self.len - back)
  }
}

///|
fn OutputBuffer::copy_from_distance(
  self : OutputBuffer,
  distance : Int,
  len : Int,
) -> Unit raise BrotliError {
  guard distance > 0 else {
    raise BrotliError::CorruptInput("invalid backward distance")
  }
  guard distance <= self.len else {
    raise BrotliError::CorruptInput("backward distance exceeds output")
  }
  if len <= 0 {
    return
  }
  self.ensure_capacity(len)
  for _ in 0..<len {
    self.buf.unsafe_set(self.len, self.buf.unsafe_get(self.len - distance))
    self.len += 1
  }
}

///|
fn OutputBuffer::to_bytes(self : OutputBuffer) -> Bytes {
  let result = @blit.make_uninit(self.len)
  @blit.blit_fixed_array(result, 0, self.buf, 0, self.len)
  result.unsafe_reinterpret_as_bytes()
}

///|
priv struct BlockCategory {
  num_types : Int
  type_decoder : PrefixDecoder?
  len_decoder : PrefixDecoder?
  mut remaining : Int
  mut prev0 : Int
  mut prev1 : Int
  mut current : Int
}

///|
fn BlockCategory::new_single() -> BlockCategory {
  {
    num_types: 1,
    type_decoder: None,
    len_decoder: None,
    remaining: brotli_block_size_cap,
    prev0: 1,
    prev1: 0,
    current: 0,
  }
}

///|
fn BlockCategory::new_multi(
  num_types : Int,
  type_decoder : PrefixDecoder,
  len_decoder : PrefixDecoder,
  initial_length : Int,
) -> BlockCategory {
  {
    num_types,
    type_decoder: Some(type_decoder),
    len_decoder: Some(len_decoder),
    remaining: initial_length,
    prev0: 1,
    prev1: 0,
    current: 0,
  }
}

///|
fn BlockCategory::current_type(self : BlockCategory) -> Int {
  self.current
}

///|
fn BlockCategory::consume(self : BlockCategory) -> Unit {
  self.remaining -= 1
}

///|
fn BlockCategory::ensure_current(
  self : BlockCategory,
  reader : BitReader,
) -> Unit raise BrotliError {
  if self.remaining != 0 {
    return
  }
  self.switch(reader)
}

///|
fn BlockCategory::switch(
  self : BlockCategory,
  reader : BitReader,
) -> Unit raise BrotliError {
  guard self.num_types >= 2 else {
    self.remaining = brotli_block_size_cap
    self.current = 0
    return
  }
  let type_decoder = match self.type_decoder {
    Some(decoder) => decoder
    None => raise BrotliError::CorruptInput("missing block type decoder")
  }
  let len_decoder = match self.len_decoder {
    Some(decoder) => decoder
    None => raise BrotliError::CorruptInput("missing block length decoder")
  }
  let symbol = decode_symbol_required(type_decoder, reader)
  let next = if symbol == 1 {
    self.prev1 + 1
  } else if symbol == 0 {
    self.prev0
  } else {
    symbol - 2
  }
  let block_type = if next >= self.num_types {
    next - self.num_types
  } else {
    next
  }
  self.prev0 = self.prev1
  self.prev1 = block_type
  self.current = block_type
  self.remaining = read_block_length(reader, len_decoder)
}

///|
priv struct DecodedDistance {
  distance : Int
  should_push : Bool
}

///|
fn decode_symbol_required(
  decoder : PrefixDecoder,
  reader : BitReader,
) -> Int raise BrotliError {
  match decoder.decode(reader) {
    Some(value) => value
    None => raise BrotliError::UnexpectedEOF
  }
}

///|
fn read_var_len_uint8(reader : BitReader) -> Int raise BrotliError {
  if reader.read_required(1) == 0 {
    return 0
  }
  let n = reader.read_required(3)
  if n == 0 {
    return 1
  }
  (1 << n) + reader.read_required(n)
}

///|
fn read_block_length(
  reader : BitReader,
  decoder : PrefixDecoder,
) -> Int raise BrotliError {
  let symbol = decode_symbol_required(decoder, reader)
  let extra_bits = block_length_prefix_extra_bits(symbol)
  let extra = reader.read_required(extra_bits)
  block_length_value(symbol, extra)
}

///|
fn read_block_category(reader : BitReader) -> BlockCategory raise BrotliError {
  let num_types = read_var_len_uint8(reader) + 1
  if num_types < 2 {
    return BlockCategory::new_single()
  }
  let type_decoder = read_prefix_code(reader, num_types + 2)
  let len_decoder = read_prefix_code(reader, 26)
  let initial_length = read_block_length(reader, len_decoder)
  BlockCategory::new_multi(num_types, type_decoder, len_decoder, initial_length)
}

///|
fn read_context_map_with_trees(
  reader : BitReader,
  size : Int,
) -> (Bytes, Int) raise BrotliError {
  let num_trees = read_var_len_uint8(reader) + 1
  (decode_context_map(reader, size, num_trees), num_trees)
}

///|
fn read_context_modes_array(
  reader : BitReader,
  count : Int,
) -> Array[ContextMode] raise BrotliError {
  let result : Array[ContextMode] = []
  for _ in 0..<count {
    result.push(context_mode_from_bits(reader.read_required(2)))
  }
  result
}

///|
fn read_tree_group(
  reader : BitReader,
  num_trees : Int,
  alphabet_size : Int,
) -> Array[PrefixDecoder] raise BrotliError {
  let trees : Array[PrefixDecoder] = []
  for _ in 0..<num_trees {
    trees.push(read_prefix_code(reader, alphabet_size))
  }
  trees
}

///|
fn distance_alphabet_size(
  npostfix : Int,
  ndirect : Int,
) -> Int raise BrotliError {
  guard npostfix >= 0 && npostfix <= 3 else {
    raise BrotliError::CorruptInput("invalid NPOSTFIX")
  }
  guard ndirect >= 0 && ndirect <= 120 else {
    raise BrotliError::CorruptInput("invalid NDIRECT")
  }
  16 + ndirect + (brotli_max_distance_bits << (npostfix + 1))
}

///|
fn max_backward_distance(wbits : Int) -> Int {
  (1 << wbits) - 16
}

///|
fn resolve_distance_symbol_from_tree(
  reader : BitReader,
  history : DistanceHistory,
  distance_tree : PrefixDecoder,
  npostfix : Int,
  ndirect : Int,
) -> DecodedDistance raise BrotliError {
  let symbol = decode_symbol_required(distance_tree, reader)
  if symbol < 16 {
    return {
      distance: history.resolve_short_code(symbol),
      should_push: symbol != 0,
    }
  }
  let extra_bits = distance_extra_bits(symbol, npostfix, ndirect)
  let extra = reader.read_required(extra_bits)
  {
    distance: decode_distance_symbol(symbol, extra, npostfix, ndirect, history),
    should_push: true,
  }
}

///|
fn append_metadata(
  reader : BitReader,
  header : MetaBlockHeader,
) -> Unit raise BrotliError {
  let skipped = reader.read_aligned_bytes(header.length)
  guard skipped.length() == header.length else {
    raise BrotliError::UnexpectedEOF
  }
}

///|
fn append_uncompressed_block(
  reader : BitReader,
  header : MetaBlockHeader,
  output : OutputBuffer,
) -> Unit raise BrotliError {
  reader.align_to_byte_zero()
  let bytes = reader.read_aligned_bytes(header.length)
  guard bytes.length() == header.length else {
    raise BrotliError::UnexpectedEOF
  }
  output.write_bytes(bytes)
}

///|
fn decode_compressed_meta_block(
  reader : BitReader,
  meta_block_len : Int,
  output : OutputBuffer,
  max_backward : Int,
) -> Unit raise BrotliError {
  let literal_blocks = read_block_category(reader)
  let command_blocks = read_block_category(reader)
  let distance_blocks = read_block_category(reader)

  let params = reader.read_required(6)
  let npostfix = params & 0x3
  let ndirect = params >> 2 << npostfix

  let context_modes = read_context_modes_array(reader, literal_blocks.num_types)
  let (literal_context_map, num_literal_trees) = read_context_map_with_trees(
    reader,
    literal_blocks.num_types << brotli_literal_context_bits,
  )
  let (dist_context_map, num_dist_trees) = read_context_map_with_trees(
    reader,
    distance_blocks.num_types << brotli_distance_context_bits,
  )

  let literal_trees = read_tree_group(
    reader, num_literal_trees, brotli_num_literal_symbols,
  )
  let command_trees = read_tree_group(
    reader,
    command_blocks.num_types,
    brotli_num_command_symbols,
  )
  let distance_trees = read_tree_group(
    reader,
    num_dist_trees,
    distance_alphabet_size(npostfix, ndirect),
  )

  let history = DistanceHistory::new()
  let mut remaining = meta_block_len

  while remaining > 0 {
    command_blocks.ensure_current(reader)
    let command_decoder = command_trees[command_blocks.current_type()]
    let command_symbol = decode_symbol_required(command_decoder, reader)
    let insert_extra_bits = command_insert_extra_bits(command_symbol)
    let copy_extra_bits = command_copy_extra_bits(command_symbol)
    let insert_extra = reader.read_required(insert_extra_bits)
    let copy_extra = reader.read_required(copy_extra_bits)
    let command = command_parameters(command_symbol, insert_extra, copy_extra)
    command_blocks.consume()

    remaining -= command.insert_length
    guard remaining >= 0 else {
      raise BrotliError::CorruptInput("insert length exceeds metablock")
    }

    for _ in 0..<command.insert_length {
      literal_blocks.ensure_current(reader)
      let literal_block_type = literal_blocks.current_type()
      let context_base = literal_block_type << brotli_literal_context_bits
      let context = literal_context_id(
        context_modes[literal_block_type],
        output.last_byte(1),
        output.last_byte(2),
      )
      let literal_tree_index = literal_context_map[context_base + context].to_int()
      guard literal_tree_index >= 0 &&
        literal_tree_index < literal_trees.length() else {
        raise BrotliError::CorruptInput("literal tree index out of range")
      }
      let literal = decode_symbol_required(
        literal_trees[literal_tree_index],
        reader,
      )
      output.write_byte(literal.to_byte())
      literal_blocks.consume()
    }

    if remaining == 0 {
      continue
    }

    let distance = match command.implied_distance_code {
      Some(code) =>
        if code == 0 {
          { distance: history.recent(1), should_push: false }
        } else {
          { distance: history.resolve_short_code(code), should_push: true }
        }
      None => {
        distance_blocks.ensure_current(reader)
        let dist_block_type = distance_blocks.current_type()
        let dist_context_base = dist_block_type << brotli_distance_context_bits
        let dist_tree_index = dist_context_map[dist_context_base +
        command.distance_context].to_int()
        guard dist_tree_index >= 0 && dist_tree_index < distance_trees.length() else {
          raise BrotliError::CorruptInput("distance tree index out of range")
        }
        let decoded = resolve_distance_symbol_from_tree(
          reader,
          history,
          distance_trees[dist_tree_index],
          npostfix,
          ndirect,
        )
        distance_blocks.consume()
        decoded
      }
    }

    let max_distance = if output.length() < max_backward {
      output.length()
    } else {
      max_backward
    }

    if distance.distance > max_distance {
      let word = static_dictionary_reference(
        command.copy_length,
        distance.distance - max_distance - 1,
      )
      guard word.length() > 0 else {
        raise BrotliError::CorruptInput("invalid dictionary transform")
      }
      output.write_bytes(word)
      remaining -= word.length()
    } else {
      output.copy_from_distance(distance.distance, command.copy_length)
      remaining -= command.copy_length
      if distance.should_push {
        history.push(distance.distance)
      }
    }

    guard remaining >= 0 else {
      raise BrotliError::CorruptInput("copy length exceeds metablock")
    }
  }
}

///|
fn decode_brotli_stream(data : Bytes) -> StreamDecodeResult raise BrotliError {
  let reader = BitReader::new()
  reader.set_input(data[:])
  let wbits = match read_window_bits(reader) {
    Some(bits) => bits
    None => raise BrotliError::UnexpectedEOF
  }
  let output = OutputBuffer::new((data.length() * 2).max(32768))
  let max_backward = max_backward_distance(wbits)

  while true {
    let header = match read_meta_block_header(reader) {
      Some(value) => value
      None => raise BrotliError::UnexpectedEOF
    }
    if header.is_last_empty {
      reader.align_to_byte_zero()
      return { output: output.to_bytes(), remaining: reader.remaining_bytes() }
    }
    if header.is_metadata {
      append_metadata(reader, header)
    } else if header.is_uncompressed {
      append_uncompressed_block(reader, header, output)
    } else {
      decode_compressed_meta_block(reader, header.length, output, max_backward)
    }
    if header.is_last {
      reader.align_to_byte_zero()
      return { output: output.to_bytes(), remaining: reader.remaining_bytes() }
    }
  }
  { output: output.to_bytes(), remaining: reader.remaining_bytes() }
}
