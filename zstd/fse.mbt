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
    if norm_counts[sym] == -1 {
      symbols[high_threshold] = sym.to_byte()
      high_threshold -= 1
    }
  }
  // Second pass: spread remaining symbols
  let step = (table_size >> 1) + (table_size >> 3) + 3
  let mask = table_size - 1
  let mut pos = 0
  for sym in 0..<=max_symbol {
    let count = norm_counts[sym]
    if count <= 0 {
      continue
    }
    for _ in 0..<count {
      symbols[pos] = sym.to_byte()
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
  for sym in 0..=max_symbol {
    symbol_next[sym] = if norm_counts[sym] == -1 { 1 } else { norm_counts[sym] }
  }
  for i in 0..<table_size {
    let sym = symbols[i].to_int()
    let next_state = symbol_next[sym]
    symbol_next[sym] = next_state + 1
    let high_bit = highest_bit(next_state) - 1 // position of highest set bit
    let nb = accuracy_log - high_bit
    num_bits[i] = nb.to_byte()
    new_state_base[i] = (next_state << nb) - table_size
  }
  { symbols, num_bits, new_state_base, _accuracy_log: accuracy_log, _table_size: table_size }
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
/// Decodes an FSE-encoded stream using the given table.
fn fse_decode_symbol(table : FseTable, state : Int) -> (Byte, Int, Int) {
  let s = if state >= 0 && state < table.symbols.length() { state } else { 0 }
  let sym = table.symbols[s]
  let nb = table.num_bits[s].to_int()
  let base = table.new_state_base[s]
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
/// Baseline and extra bits tables for literal lengths.
let ll_baselines : FixedArray[Int] = {
  let a = FixedArray::make(36, 0)
  // Codes 0-15 map directly to values 0-15
  for i in 0..<16 {
    a[i] = i
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
    a[i] = i + 3
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
