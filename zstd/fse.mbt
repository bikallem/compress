///|
/// FSE (Finite State Entropy) table for decoding.
priv struct FseTable {
  symbols : FixedArray[Byte]
  num_bits : FixedArray[Byte]
  new_state_base : FixedArray[Int]
  _accuracy_log : Int
  _table_size : Int
}

///|
/// Builds an FSE table from normalized frequencies.
fn FseTable::build(
  norm_counts : FixedArray[Int],
  max_symbol : Int,
  accuracy_log : Int,
) -> FseTable {
  let table_size = 1 << accuracy_log
  let symbols = FixedArray::make(table_size, b'\x00')
  let num_bits = FixedArray::make(table_size, b'\x00')
  let new_state_base = FixedArray::make(table_size, 0)
  // Step 1: Spread symbols across the table
  let mut high_threshold = table_size - 1
  // First pass: place symbols with count == -1 (less than 1)
  for sym in 0..<=max_symbol {
    if norm_counts.unsafe_get(sym) == -1 {
      symbols.unsafe_set(high_threshold, sym.to_byte())
      high_threshold -= 1
    }
  }
  // Second pass: spread remaining symbols
  let step = (table_size >> 1) + (table_size >> 3) + 3
  let mask = table_size - 1
  let mut pos = 0
  for sym in 0..<=max_symbol {
    let count = norm_counts.unsafe_get(sym)
    if count <= 0 {
      continue
    }
    for _ in 0..<count {
      symbols.unsafe_set(pos, sym.to_byte())
      pos = (pos + step) & mask
      while pos > high_threshold {
        pos = (pos + step) & mask
      }
    }
  }
  // Step 2: Build decoding table using the reference algorithm.
  // For each symbol, maintain a counter starting at the symbol's count
  // (or 1 for -1 entries). Each table entry gets nbBits and newState
  // based on this per-symbol counter.
  let symbol_next = FixedArray::make(max_symbol + 1, 0)
  for sym in 0..<=max_symbol {
    symbol_next.unsafe_set(
      sym,
      if norm_counts.unsafe_get(sym) == -1 {
        1
      } else {
        norm_counts.unsafe_get(sym)
      },
    )
  }
  for i in 0..<table_size {
    let sym = symbols.unsafe_get(i).to_int()
    let next_state = symbol_next.unsafe_get(sym)
    symbol_next.unsafe_set(sym, next_state + 1)
    let high_bit = highest_bit(next_state) - 1 // position of highest set bit
    let nb = accuracy_log - high_bit
    num_bits.unsafe_set(i, nb.to_byte())
    new_state_base.unsafe_set(i, (next_state << nb) - table_size)
  }
  {
    symbols,
    num_bits,
    new_state_base,
    _accuracy_log: accuracy_log,
    _table_size: table_size,
  }
}

///|
fn highest_bit(n_ : Int) -> Int {
  if n_ <= 0 {
    return 0
  }
  let mut bits = 0
  for n = n_; n > 0; n = n >> 1 {
    bits += 1
  }
  bits
}

///|
const FSE_MIN_TABLELOG : Int = 5

///|
fn read_le32_padded(src : BytesView, pos : Int) -> UInt {
  let b0 = if pos < src.length() { src.unsafe_get(pos).to_uint() } else { 0U }
  let b1 = if pos + 1 < src.length() {
    src.unsafe_get(pos + 1).to_uint()
  } else {
    0U
  }
  let b2 = if pos + 2 < src.length() {
    src.unsafe_get(pos + 2).to_uint()
  } else {
    0U
  }
  let b3 = if pos + 3 < src.length() {
    src.unsafe_get(pos + 3).to_uint()
  } else {
    0U
  }
  b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
}

///|
fn reload_ncount_bits(
  src : BytesView,
  ip : Int,
  bit_count : Int,
) -> (UInt, Int, Int) {
  let next_ip = ip + (bit_count >> 3)
  let next_bit_count = bit_count & 7
  (read_le32_padded(src, next_ip) >> next_bit_count, next_ip, next_bit_count)
}

///|
fn read_ncount(
  src : BytesView,
  max_symbol : Int,
  max_accuracy_log : Int,
) -> (FixedArray[Int], Int, Int, Int) raise ZstdError {
  guard src.length() > 0 else {
    raise ZstdError::CorruptData("empty FSE table description")
  }
  let normalized = FixedArray::make(max_symbol + 1, 0)
  let mut bit_stream = read_le32_padded(src, 0)
  let mut accuracy_log = (bit_stream & 0x0FU).reinterpret_as_int() +
    FSE_MIN_TABLELOG
  guard accuracy_log <= max_accuracy_log else {
    raise ZstdError::CorruptData("FSE accuracy log exceeds supported limit")
  }
  bit_stream = bit_stream >> 4
  let table_log = accuracy_log
  let mut bit_count = 4
  let mut remaining = (1 << table_log) + 1
  let mut threshold = 1 << table_log
  accuracy_log += 1
  let max_symbol_count = max_symbol + 1
  let mut charnum = 0
  let mut previous_zero = false
  let mut ip = 0
  while true {
    if previous_zero {
      while true {
        let repeat = (bit_stream & 0x03U).reinterpret_as_int()
        bit_stream = bit_stream >> 2
        bit_count += 2
        charnum += repeat
        guard charnum <= max_symbol_count else {
          raise ZstdError::CorruptData(
            "FSE table description repeats past alphabet",
          )
        }
        if repeat != 3 {
          break
        }
        let (next_stream, next_ip, next_bit_count) = reload_ncount_bits(
          src, ip, bit_count,
        )
        bit_stream = next_stream
        ip = next_ip
        bit_count = next_bit_count
      }
    }
    let max = 2 * threshold - 1 - remaining
    let threshold_mask = (threshold - 1).reinterpret_as_uint()
    let raw_count = if (bit_stream & threshold_mask).reinterpret_as_int() < max {
      bit_count += accuracy_log - 1
      (bit_stream & threshold_mask).reinterpret_as_int()
    } else {
      let mut value = (bit_stream & (2 * threshold - 1).reinterpret_as_uint()).reinterpret_as_int()
      if value >= threshold {
        value -= max
      }
      bit_count += accuracy_log
      value
    }
    let count = raw_count - 1
    guard charnum < max_symbol_count else {
      raise ZstdError::CorruptData("FSE table description exceeds alphabet")
    }
    normalized.unsafe_set(charnum, count)
    charnum += 1
    previous_zero = count == 0
    if count >= 0 {
      remaining -= count
    } else {
      remaining += count
    }
    if remaining < threshold {
      guard remaining > 0 else {
        raise ZstdError::CorruptData("oversubscribed FSE table description")
      }
      if remaining == 1 {
        break
      }
      accuracy_log = highest_bit(remaining)
      threshold = 1 << (accuracy_log - 1)
    }
    guard charnum <= max_symbol_count else {
      raise ZstdError::CorruptData("FSE table description exceeds alphabet")
    }
    let (next_stream, next_ip, next_bit_count) = reload_ncount_bits(
      src, ip, bit_count,
    )
    bit_stream = next_stream
    ip = next_ip
    bit_count = next_bit_count
  }
  guard remaining == 1 else {
    raise ZstdError::CorruptData("incomplete FSE table description")
  }
  guard bit_count <= 32 else {
    raise ZstdError::CorruptData("invalid FSE table description bit count")
  }
  let bytes_read = ip + ((bit_count + 7) >> 3)
  guard bytes_read <= src.length() else { raise ZstdError::UnexpectedEOF }
  (normalized, charnum - 1, table_log, bytes_read)
}

///|
fn build_fse_table_from_description(
  src : BytesView,
  max_symbol : Int,
  max_accuracy_log : Int,
) -> (FseTable, Int) raise ZstdError {
  let (normalized, actual_max_symbol, table_log, bytes_read) = read_ncount(
    src, max_symbol, max_accuracy_log,
  )
  (FseTable::build(normalized, actual_max_symbol, table_log), bytes_read)
}

///|
/// Decodes an FSE-encoded stream using the given table.
fn fse_decode_symbol(table : FseTable, state : Int) -> (Byte, Int, Int) {
  let s = if state >= 0 && state < table.symbols.length() { state } else { 0 }
  let sym = table.symbols.unsafe_get(s)
  let nb = table.num_bits.unsafe_get(s).to_int()
  let base = table.new_state_base.unsafe_get(s)
  (sym, nb, base)
}

///|
/// Predefined FSE table for literal lengths (from RFC 8878 section 3.1.1).
let ll_default_norm : FixedArray[Int] = {
  let a = FixedArray::make(36, 0)
  a[0] = 4
  a[1] = 3
  a[2] = 2
  a[3] = 2
  a[4] = 2
  a[5] = 2
  a[6] = 2
  a[7] = 2
  a[8] = 2
  a[9] = 2
  a[10] = 2
  a[11] = 2
  a[12] = 2
  a[13] = 1
  a[14] = 1
  a[15] = 1
  a[16] = 2
  a[17] = 2
  a[18] = 2
  a[19] = 2
  a[20] = 2
  a[21] = 2
  a[22] = 2
  a[23] = 2
  a[24] = 2
  a[25] = 3
  a[26] = 2
  a[27] = 1
  a[28] = 1
  a[29] = 1
  a[30] = 1
  a[31] = 1
  a[32] = -1
  a[33] = -1
  a[34] = -1
  a[35] = -1
  a
}

///|
/// Predefined FSE table for match lengths (from RFC 8878).
let ml_default_norm : FixedArray[Int] = {
  let a = FixedArray::make(53, 0)
  a[0] = 1
  a[1] = 4
  a[2] = 3
  a[3] = 2
  a[4] = 2
  a[5] = 2
  a[6] = 2
  a[7] = 2
  a[8] = 2
  a[9] = 1
  a[10] = 1
  a[11] = 1
  a[12] = 1
  a[13] = 1
  a[14] = 1
  a[15] = 1
  a[16] = 1
  a[17] = 1
  a[18] = 1
  a[19] = 1
  a[20] = 1
  a[21] = 1
  a[22] = 1
  a[23] = 1
  a[24] = 1
  a[25] = 1
  a[26] = 1
  a[27] = 1
  a[28] = 1
  a[29] = 1
  a[30] = 1
  a[31] = 1
  a[32] = 1
  a[33] = 1
  a[34] = 1
  a[35] = 1
  a[36] = 1
  a[37] = 1
  a[38] = 1
  a[39] = 1
  a[40] = 1
  a[41] = 1
  a[42] = 1
  a[43] = 1
  a[44] = 1
  a[45] = 1
  a[46] = -1
  a[47] = -1
  a[48] = -1
  a[49] = -1
  a[50] = -1
  a[51] = -1
  a[52] = -1
  a
}

///|
/// Predefined FSE table for offset codes (from RFC 8878).
let of_default_norm : FixedArray[Int] = {
  let a = FixedArray::make(29, 0)
  a[0] = 1
  a[1] = 1
  a[2] = 1
  a[3] = 1
  a[4] = 1
  a[5] = 1
  a[6] = 2
  a[7] = 2
  a[8] = 2
  a[9] = 1
  a[10] = 1
  a[11] = 1
  a[12] = 1
  a[13] = 1
  a[14] = 1
  a[15] = 1
  a[16] = 1
  a[17] = 1
  a[18] = 1
  a[19] = 1
  a[20] = 1
  a[21] = 1
  a[22] = 1
  a[23] = 1
  a[24] = -1
  a[25] = -1
  a[26] = -1
  a[27] = -1
  a[28] = -1
  a
}

///|
/// Default accuracy logs.
const LL_DEFAULT_ACCURACY : Int = 6

///|
const ML_DEFAULT_ACCURACY : Int = 6

///|
const OF_DEFAULT_ACCURACY : Int = 5

///|
let ll_default_table : FseTable = FseTable::build(
  ll_default_norm,
  35,
  LL_DEFAULT_ACCURACY,
)

///|
let ml_default_table : FseTable = FseTable::build(
  ml_default_norm,
  52,
  ML_DEFAULT_ACCURACY,
)

///|
let of_default_table : FseTable = FseTable::build(
  of_default_norm,
  28,
  OF_DEFAULT_ACCURACY,
)

///|
/// Baseline and extra bits tables for literal lengths.
let ll_baselines : FixedArray[Int] = {
  let a = FixedArray::make(36, 0)
  // Codes 0-15 map directly to values 0-15
  for i in 0..<16 {
    a.unsafe_set(i, i)
  }
  a[16] = 16
  a[17] = 18
  a[18] = 20
  a[19] = 22
  a[20] = 24
  a[21] = 28
  a[22] = 32
  a[23] = 40
  a[24] = 48
  a[25] = 64
  a[26] = 128
  a[27] = 256
  a[28] = 512
  a[29] = 1024
  a[30] = 2048
  a[31] = 4096
  a[32] = 8192
  a[33] = 16384
  a[34] = 32768
  a[35] = 65536
  a
}

///|
let ll_extra_bits : FixedArray[Int] = {
  let a = FixedArray::make(36, 0)
  // Codes 0-15: 0 extra bits
  a[16] = 1
  a[17] = 1
  a[18] = 1
  a[19] = 1
  a[20] = 2
  a[21] = 2
  a[22] = 3
  a[23] = 3
  a[24] = 4
  a[25] = 6
  a[26] = 7
  a[27] = 8
  a[28] = 9
  a[29] = 10
  a[30] = 11
  a[31] = 12
  a[32] = 13
  a[33] = 14
  a[34] = 15
  a[35] = 16
  a
}

///|
/// Baseline and extra bits tables for match lengths.
let ml_baselines : FixedArray[Int] = {
  let a = FixedArray::make(53, 0)
  // Codes 0-31 map to values 3-34
  for i in 0..<32 {
    a.unsafe_set(i, i + 3)
  }
  a[32] = 35
  a[33] = 37
  a[34] = 39
  a[35] = 41
  a[36] = 43
  a[37] = 47
  a[38] = 51
  a[39] = 59
  a[40] = 67
  a[41] = 83
  a[42] = 99
  a[43] = 131
  a[44] = 259
  a[45] = 515
  a[46] = 1027
  a[47] = 2051
  a[48] = 4099
  a[49] = 8195
  a[50] = 16387
  a[51] = 32771
  a[52] = 65539
  a
}

///|
let ml_extra_bits : FixedArray[Int] = {
  let a = FixedArray::make(53, 0)
  // Codes 0-31: 0 extra bits
  a[32] = 1
  a[33] = 1
  a[34] = 1
  a[35] = 1
  a[36] = 2
  a[37] = 2
  a[38] = 3
  a[39] = 3
  a[40] = 4
  a[41] = 4
  a[42] = 5
  a[43] = 7
  a[44] = 8
  a[45] = 9
  a[46] = 10
  a[47] = 11
  a[48] = 12
  a[49] = 13
  a[50] = 14
  a[51] = 15
  a[52] = 16
  a
}
