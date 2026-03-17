///|
fn write_simple_prefix(
  writer : BitWriter,
  alphabet_size : Int,
  symbols : Array[Int],
  tree_select? : Int = 0,
) -> Unit {
  writer.write_bits(1U, 2)
  writer.write_bits((symbols.length() - 1).reinterpret_as_uint(), 2)
  let bits = alphabet_bits(alphabet_size)
  for _, symbol in symbols {
    writer.write_bits(symbol.reinterpret_as_uint(), bits)
  }
  if symbols.length() == 4 {
    writer.write_bits(tree_select.reinterpret_as_uint(), 1)
  }
}

///|
fn write_code_length_prefix_value(writer : BitWriter, value : Int) -> Unit {
  match value {
    0 => writer.write_bits(0U, 2)
    1 => writer.write_bits(7U, 4)
    2 => writer.write_bits(3U, 3)
    3 => writer.write_bits(2U, 2)
    4 => writer.write_bits(1U, 2)
    5 => writer.write_bits(15U, 4)
    _ => abort("unexpected code-length prefix value")
  }
}

///|
fn write_symbol_with_lengths(
  writer : BitWriter,
  lengths : FixedArray[Int],
  symbol : Int,
) -> Unit {
  let codes = build_canonical_codes(lengths, MAX_PREFIX_CODE_BITS) catch {
    e => abort(e.to_string())
  }
  let code = codes[symbol]
  let len = lengths[symbol]
  writer.write_bits(reverse_bits(code, len).reinterpret_as_uint(), len)
}

///|
test "brotli canonical codes match RFC example" {
  let lengths : FixedArray[Int] = [2, 1, 3, 3]
  let codes = build_canonical_codes(lengths, MAX_PREFIX_CODE_BITS) catch {
    e => abort(e.to_string())
  }
  assert_eq(codes[0], 2)
  assert_eq(codes[1], 0)
  assert_eq(codes[2], 6)
  assert_eq(codes[3], 7)
}

///|
test "brotli simple prefix code decodes unsorted symbols" {
  let writer = BitWriter::new()
  write_simple_prefix(writer, 8, [5, 2, 1])
  let lengths = FixedArray::make(8, 0)
  lengths[5] = 1
  lengths[2] = 2
  lengths[1] = 2
  write_symbol_with_lengths(writer, lengths, 5)
  write_symbol_with_lengths(writer, lengths, 1)
  write_symbol_with_lengths(writer, lengths, 2)
  let encoded = writer.finish()

  let reader = BitReader::new()
  reader.set_input(encoded[:])
  let decoder = read_prefix_code(reader, 8)
  assert_eq(decoder.decode(reader), Some(5))
  assert_eq(decoder.decode(reader), Some(1))
  assert_eq(decoder.decode(reader), Some(2))
}

///|
test "brotli complex prefix code decodes canonical symbols" {
  let writer = BitWriter::new()
  writer.write_bits(0U, 2) // complex prefix code, HSKIP=0
  write_code_length_prefix_value(writer, 1) // symbol 1
  write_code_length_prefix_value(writer, 2) // symbol 2
  write_code_length_prefix_value(writer, 0) // symbol 3
  write_code_length_prefix_value(writer, 0) // symbol 4
  write_code_length_prefix_value(writer, 2) // symbol 0

  let code_length_lengths = FixedArray::make(18, 0)
  code_length_lengths[1] = 1
  code_length_lengths[2] = 2
  code_length_lengths[0] = 2
  write_symbol_with_lengths(writer, code_length_lengths, 1)
  write_symbol_with_lengths(writer, code_length_lengths, 2)
  write_symbol_with_lengths(writer, code_length_lengths, 2)

  let actual_lengths : FixedArray[Int] = [1, 2, 2, 0]
  write_symbol_with_lengths(writer, actual_lengths, 1)
  write_symbol_with_lengths(writer, actual_lengths, 0)
  write_symbol_with_lengths(writer, actual_lengths, 2)
  let encoded = writer.finish()

  let reader = BitReader::new()
  reader.set_input(encoded[:])
  let decoder = read_prefix_code(reader, 4)
  assert_eq(decoder.decode(reader), Some(1))
  assert_eq(decoder.decode(reader), Some(0))
  assert_eq(decoder.decode(reader), Some(2))
}
