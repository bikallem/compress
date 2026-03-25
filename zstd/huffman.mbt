///|
const ZSTD_HUFFMAN_MAX_BITS : Int = 12

///|
priv struct ZstdHuffmanTable {
  entries : FixedArray[UInt]
  max_bits : Int
}

///|
fn ZstdHuffmanTable::from_description(
  src : BytesView,
) -> (ZstdHuffmanTable, Int) raise ZstdError {
  guard src.length() > 0 else { raise ZstdError::UnexpectedEOF }
  let header = src.unsafe_get(0).to_int()
  if header >= 128 {
    let num_weights = header - 127
    let bytes_used = 1 + ((num_weights + 1) >> 1)
    guard bytes_used <= src.length() else { raise ZstdError::UnexpectedEOF }
    let weights : Array[Int] = []
    for i in 0..<num_weights {
      let packed = src.unsafe_get(1 + (i >> 1)).to_int()
      let weight = if (i & 1) == 0 { packed >> 4 } else { packed & 0x0F }
      weights.push(weight)
    }
    (ZstdHuffmanTable::from_weights(weights), bytes_used)
  } else {
    let payload_size = header
    guard 1 + payload_size <= src.length() else {
      raise ZstdError::UnexpectedEOF
    }
    let weights = decode_huffman_weights_fse(src[1:1 + payload_size])
    (ZstdHuffmanTable::from_weights(weights), 1 + payload_size)
  }
}

///|
fn ZstdHuffmanTable::from_weights(
  partial_weights : Array[Int],
) -> ZstdHuffmanTable raise ZstdError {
  guard partial_weights.length() > 0 else {
    raise ZstdError::CorruptData("empty Huffman weight description")
  }
  let mut weight_total = 0
  for weight in partial_weights {
    guard weight >= 0 && weight <= ZSTD_HUFFMAN_MAX_BITS else {
      raise ZstdError::CorruptData("invalid Huffman weight")
    }
    if weight > 0 {
      weight_total += 1 << weight >> 1
    }
  }
  guard weight_total > 0 else {
    raise ZstdError::CorruptData("empty Huffman table")
  }
  let table_log = highest_bit(weight_total)
  guard table_log <= ZSTD_HUFFMAN_MAX_BITS else {
    raise ZstdError::CorruptData("Huffman table exceeds supported depth")
  }
  let total = 1 << table_log
  let rest = total - weight_total
  guard rest > 0 && (rest & (rest - 1)) == 0 else {
    raise ZstdError::CorruptData("invalid implied Huffman weight")
  }
  let last_weight = highest_bit(rest)
  guard last_weight > 0 && last_weight <= table_log else {
    raise ZstdError::CorruptData("invalid final Huffman weight")
  }
  let num_symbols = partial_weights.length() + 1
  guard num_symbols <= 256 else {
    raise ZstdError::CorruptData("too many Huffman symbols")
  }
  let weights = FixedArray::make(num_symbols, 0)
  for i in 0..<partial_weights.length() {
    let weight = partial_weights.unsafe_get(i)
    weights.unsafe_set(i, weight)
  }
  weights.unsafe_set(num_symbols - 1, last_weight)
  build_huffman_table(weights, num_symbols, table_log)
}

///|
fn build_huffman_table(
  weights : FixedArray[Int],
  num_symbols : Int,
  table_log : Int,
) -> ZstdHuffmanTable raise ZstdError {
  let entries = FixedArray::make(1 << table_log, 0U)
  let rank_val = FixedArray::make(table_log + 1, 0)
  for sym in 0..<num_symbols {
    let weight = weights.unsafe_get(sym)
    guard weight >= 0 && weight <= table_log else {
      raise ZstdError::CorruptData("invalid Huffman table weight")
    }
    rank_val.unsafe_set(weight, rank_val.unsafe_get(weight) + 1)
  }
  let rank_start = FixedArray::make(table_log + 1, 0)
  let mut next_rank_start = 0
  for weight in 0..<=table_log {
    rank_start.unsafe_set(weight, next_rank_start)
    next_rank_start += rank_val.unsafe_get(weight)
  }
  let symbols = FixedArray::make(num_symbols, b'\x00')
  for sym in 0..<num_symbols {
    let weight = weights.unsafe_get(sym)
    let idx = rank_start.unsafe_get(weight)
    symbols.unsafe_set(idx, sym.to_byte())
    rank_start.unsafe_set(weight, idx + 1)
  }
  let mut symbol_idx = rank_val.unsafe_get(0)
  let mut table_idx = 0
  for weight in 1..<=table_log {
    let symbol_count = rank_val.unsafe_get(weight)
    let length = 1 << weight >> 1
    let n_bits = table_log + 1 - weight
    for i in 0..<symbol_count {
      let entry = (symbols.unsafe_get(symbol_idx + i).to_uint() << 8) |
        n_bits.reinterpret_as_uint()
      for j in 0..<length {
        entries.unsafe_set(table_idx + j, entry)
      }
      table_idx += length
    }
    symbol_idx += symbol_count
  }
  guard table_idx == entries.length() else {
    raise ZstdError::CorruptData("incomplete Huffman table")
  }
  { entries, max_bits: table_log }
}

///|
fn ZstdHuffmanTable::decode_symbol(
  self : ZstdHuffmanTable,
  br : BackwardBitReader,
) -> Byte raise ZstdError {
  let entry = self.entries.unsafe_get(
    br.peek_bits(self.max_bits).reinterpret_as_int(),
  )
  guard entry != 0U else {
    raise ZstdError::CorruptData("invalid Huffman code")
  }
  let n_bits = (entry & 0xFFU).reinterpret_as_int()
  br.skip_bits(n_bits)
  ((entry >> 8) & 0xFFU).to_byte()
}

///|
fn ZstdHuffmanTable::decode_stream(
  self : ZstdHuffmanTable,
  src : BytesView,
  output_size : Int,
) -> Bytes raise ZstdError {
  guard output_size >= 0 else {
    raise ZstdError::CorruptData("negative Huffman output size")
  }
  if output_size == 0 {
    guard src.length() == 0 else {
      raise ZstdError::CorruptData("unexpected data for empty Huffman stream")
    }
    return b""
  }
  let br = BackwardBitReader::new(src)
  let out = @blit.Buffer::new(size_hint=output_size)
  if output_size > 3 {
    let mut status = br.reload()
    while out.length() < output_size - 3 {
      guard status is BitReloadStatus::Unfinished else { break }
      out.write_byte(self.decode_symbol(br))
      out.write_byte(self.decode_symbol(br))
      out.write_byte(self.decode_symbol(br))
      out.write_byte(self.decode_symbol(br))
      status = br.reload()
    }
  } else {
    ignore(br.reload())
  }
  while out.length() < output_size {
    out.write_byte(self.decode_symbol(br))
  }
  guard br.end_of_stream() else {
    raise ZstdError::CorruptData("Huffman stream not fully consumed")
  }
  out.to_bytes()
}

///|
fn decode_huffman_literals(
  table : ZstdHuffmanTable,
  src : BytesView,
  regenerated_size : Int,
  num_streams : Int,
) -> Bytes raise ZstdError {
  if num_streams == 1 {
    return table.decode_stream(src, regenerated_size)
  }
  guard num_streams == 4 else {
    raise ZstdError::CorruptData("invalid number of Huffman streams")
  }
  guard src.length() >= 6 else { raise ZstdError::UnexpectedEOF }
  let stream1_size = src.unsafe_get(0).to_int() |
    (src.unsafe_get(1).to_int() << 8)
  let stream2_size = src.unsafe_get(2).to_int() |
    (src.unsafe_get(3).to_int() << 8)
  let stream3_size = src.unsafe_get(4).to_int() |
    (src.unsafe_get(5).to_int() << 8)
  let stream4_size = src.length() -
    6 -
    stream1_size -
    stream2_size -
    stream3_size
  guard stream4_size >= 0 else {
    raise ZstdError::CorruptData("Huffman jump table exceeds stream size")
  }
  let chunk_size = (regenerated_size + 3) >> 2
  let stream4_output = regenerated_size - 3 * chunk_size
  guard stream4_output >= 0 else {
    raise ZstdError::CorruptData("invalid 4-stream Huffman literal size")
  }
  let out = @blit.Buffer::new(size_hint=regenerated_size)
  let mut pos = 6
  out.write_bytes(table.decode_stream(src[pos:pos + stream1_size], chunk_size))
  pos += stream1_size
  out.write_bytes(table.decode_stream(src[pos:pos + stream2_size], chunk_size))
  pos += stream2_size
  out.write_bytes(table.decode_stream(src[pos:pos + stream3_size], chunk_size))
  pos += stream3_size
  out.write_bytes(
    table.decode_stream(src[pos:pos + stream4_size], stream4_output),
  )
  pos += stream4_size
  guard pos == src.length() else {
    raise ZstdError::CorruptData("unused Huffman literal bytes")
  }
  out.to_bytes()
}

///|
fn decode_huffman_weights_fse(src : BytesView) -> Array[Int] raise ZstdError {
  let (table, header_size) = build_fse_table_from_description(src, 255, 6)
  let br = BackwardBitReader::new(src[header_size:])
  let mut state1 = br
    .read_bits_checked(table._accuracy_log)
    .reinterpret_as_int()
  ignore(br.reload())
  let mut state2 = br
    .read_bits_checked(table._accuracy_log)
    .reinterpret_as_int()
  match br.reload() {
    BitReloadStatus::Overflow =>
      raise ZstdError::CorruptData("truncated Huffman weight stream")
    _ => ()
  }
  let weights : Array[Int] = []
  let mut status = br.reload()
  while true {
    guard status is BitReloadStatus::Unfinished else { break }
    guard weights.length() + 4 <= 255 else {
      raise ZstdError::CorruptData("Huffman weight stream is too large")
    }
    let (sym1, bits1, base1) = fse_decode_symbol(table, state1)
    weights.push(sym1.to_int())
    state1 = base1 + br.read_bits_padded(bits1).reinterpret_as_int()
    let (sym2, bits2, base2) = fse_decode_symbol(table, state2)
    weights.push(sym2.to_int())
    state2 = base2 + br.read_bits_padded(bits2).reinterpret_as_int()
    let (sym3, bits3, base3) = fse_decode_symbol(table, state1)
    weights.push(sym3.to_int())
    state1 = base3 + br.read_bits_padded(bits3).reinterpret_as_int()
    let (sym4, bits4, base4) = fse_decode_symbol(table, state2)
    weights.push(sym4.to_int())
    state2 = base4 + br.read_bits_padded(bits4).reinterpret_as_int()
    status = br.reload()
  }
  while true {
    guard weights.length() < 255 else {
      raise ZstdError::CorruptData("Huffman weight stream is too large")
    }
    let (sym1, bits1, base1) = fse_decode_symbol(table, state1)
    weights.push(sym1.to_int())
    state1 = base1 + br.read_bits_padded(bits1).reinterpret_as_int()
    match br.reload() {
      BitReloadStatus::Overflow => {
        guard weights.length() < 255 else {
          raise ZstdError::CorruptData("Huffman weight stream is too large")
        }
        let (sym2, _, _) = fse_decode_symbol(table, state2)
        weights.push(sym2.to_int())
        break
      }
      _ => ()
    }
    guard weights.length() < 255 else {
      raise ZstdError::CorruptData("Huffman weight stream is too large")
    }
    let (sym2, bits2, base2) = fse_decode_symbol(table, state2)
    weights.push(sym2.to_int())
    state2 = base2 + br.read_bits_padded(bits2).reinterpret_as_int()
    match br.reload() {
      BitReloadStatus::Overflow => {
        guard weights.length() < 255 else {
          raise ZstdError::CorruptData("Huffman weight stream is too large")
        }
        let (sym1, _, _) = fse_decode_symbol(table, state1)
        weights.push(sym1.to_int())
        break
      }
      _ => ()
    }
  }
  weights
}
