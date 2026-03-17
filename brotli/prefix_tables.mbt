// Command lookup table for Brotli decoding (RFC 7932 section 5).
//
// Each of the 704 command symbols maps to an insert/copy length pair
// with associated extra-bits counts and a distance-code hint.

///|
struct CmdLutElement {
  insert_len_extra_bits : Byte
  copy_len_extra_bits : Byte
  distance_code : Int // 0 = implicit last distance, -1 = explicit distance needed
  context : Byte
  insert_len_offset : UInt
  copy_len_offset : UInt
} derive(Show)

///|
/// Generates the 704-entry command lookup table.
/// This is a direct translation of BrotliDecoderInitCmdLut from the C reference.
fn generate_cmd_lut() -> FixedArray[CmdLutElement] {
  let insert_length_extra_bits : FixedArray[Int] = [
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x01,
    0x02, 0x02, 0x03, 0x03, 0x04, 0x04, 0x05, 0x05,
    0x06, 0x07, 0x08, 0x09, 0x0A, 0x0C, 0x0E, 0x18,
  ]
  let copy_length_extra_bits : FixedArray[Int] = [
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x01, 0x01, 0x02, 0x02, 0x03, 0x03, 0x04, 0x04,
    0x05, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x18,
  ]
  let cell_pos : FixedArray[Int] = [0, 1, 0, 1, 8, 9, 2, 16, 10, 17, 18]
  let insert_length_offsets : FixedArray[UInt] = FixedArray::make(24, 0U)
  let copy_length_offsets : FixedArray[UInt] = FixedArray::make(24, 0U)
  insert_length_offsets[0] = 0U
  copy_length_offsets[0] = 2U
  for i = 0; i < 23; i = i + 1 {
    insert_length_offsets[i + 1] = insert_length_offsets[i] +
      (1U << insert_length_extra_bits[i])
    copy_length_offsets[i + 1] = copy_length_offsets[i] +
      (1U << copy_length_extra_bits[i])
  }
  let items : FixedArray[CmdLutElement] = FixedArray::make(
    704,
    {
      insert_len_extra_bits: b'\x00',
      copy_len_extra_bits: b'\x00',
      distance_code: 0,
      context: b'\x00',
      insert_len_offset: 0U,
      copy_len_offset: 0U,
    },
  )
  for symbol = 0; symbol < 704; symbol = symbol + 1 {
    let cell_idx = symbol >> 6
    let cp = cell_pos[cell_idx]
    let copy_code = ((cp << 3) & 0x18) + (symbol & 0x7)
    let copy_len_offset = copy_length_offsets[copy_code]
    let insert_code = (cp & 0x18) + ((symbol >> 3) & 0x7)
    let context : Byte = if copy_len_offset > 4U {
      b'\x03'
    } else {
      (copy_len_offset - 2U).to_byte()
    }
    let distance_code = if cell_idx >= 2 { -1 } else { 0 }
    items[symbol] = {
      insert_len_extra_bits: insert_length_extra_bits[insert_code].to_byte(),
      copy_len_extra_bits: copy_length_extra_bits[copy_code].to_byte(),
      distance_code,
      context,
      insert_len_offset: insert_length_offsets[insert_code],
      copy_len_offset,
    }
  }
  items
}

///|
/// The precomputed 704-entry command lookup table.
let cmd_lut : FixedArray[CmdLutElement] = generate_cmd_lut()
