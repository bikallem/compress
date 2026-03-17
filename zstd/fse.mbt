///|
/// FSE (Finite State Entropy) table for decoding.
priv struct FseTable {
  symbols : FixedArray[Byte]
  num_bits : FixedArray[Byte]
  new_state_base : FixedArray[Int]
  accuracy_log : Int
  table_size : Int
}

///|
/// Builds an FSE table from normalized frequencies.
fn FseTable::build(
  norm_counts : FixedArray[Int],
  max_symbol : Int,
  accuracy_log : Int,
) -> FseTable raise ZstdError {
  let table_size = 1 << accuracy_log
  let symbols = FixedArray::make(table_size, b'\x00')
  let num_bits = FixedArray::make(table_size, b'\x00')
  let new_state_base = FixedArray::make(table_size, 0)
  // Step 1: Spread symbols across the table
  let mut high_threshold = table_size - 1
  // First pass: place symbols with count == -1 (less than 1)
  for sym in 0..=max_symbol {
    if norm_counts[sym] == -1 {
      symbols[high_threshold] = sym.to_byte()
      high_threshold -= 1
    }
  }
  // Second pass: spread remaining symbols
  let step = (table_size >> 1) + (table_size >> 3) + 3
  let mask = table_size - 1
  let mut pos = 0
  for sym in 0..=max_symbol {
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
  // Step 2: Build decoding table
  for i in 0..<table_size {
    let sym = symbols[i].to_int()
    let count = if norm_counts[sym] == -1 { 1 } else { norm_counts[sym] }
    // Number of bits to read
    let max_bits_out = accuracy_log - highest_bit(count - 1)
    let new_state_baseline = (count << (max_bits_out + 1)) - table_size
    if i < new_state_baseline {
      num_bits[i] = (max_bits_out + 1).to_byte()
      new_state_base[i] = i - new_state_baseline + (count << (max_bits_out + 1))
    } else {
      num_bits[i] = max_bits_out.to_byte()
      new_state_base[i] = i - new_state_baseline + (count << max_bits_out)
    }
  }
  { symbols, num_bits, new_state_base, accuracy_log, table_size }
}

///|
fn highest_bit(n_ : Int) -> Int {
  if n_ <= 0 {
    return 0
  }
  let mut n = n_
  let mut bits = 0
  while n > 0 {
    bits += 1
    n = n >> 1
  }
  bits
}

///|
/// Decodes an FSE-encoded stream using the given table.
fn fse_decode_symbol(table : FseTable, state : Int) -> (Byte, Int, Int) {
  let s = if state >= 0 && state < table.symbols.length() {
    state
  } else {
    0
  }
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
  a[24] = -1
  a[25] = -1
  a[26] = -1
  a[27] = -1
  a[28] = -1
  a[29] = -1
  a[30] = -1
  a[31] = -1
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
  a[32] = -1
  a[33] = -1
  a[34] = -1
  a[35] = -1
  a[36] = -1
  a[37] = -1
  a[38] = -1
  a[39] = -1
  a[40] = -1
  a[41] = -1
  a[42] = -1
  a[43] = -1
  a[44] = -1
  a[45] = -1
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
  a[19] = 24
  a[20] = 28
  a[21] = 32
  a[22] = 40
  a[23] = 48
  a[24] = 64
  a[25] = 128
  a[26] = 256
  a[27] = 512
  a[28] = 1024
  a[29] = 2048
  a[30] = 4096
  a[31] = 8192
  a[32] = 16384
  a[33] = 32768
  a[34] = 65536
  a[35] = 131072
  a
}

///|
let ll_extra_bits : FixedArray[Int] = {
  let a = FixedArray::make(36, 0)
  // Codes 0-15: 0 extra bits
  a[16] = 1
  a[17] = 1
  a[18] = 1
  a[19] = 2
  a[20] = 2
  a[21] = 3
  a[22] = 3
  a[23] = 4
  a[24] = 6
  a[25] = 7
  a[26] = 8
  a[27] = 9
  a[28] = 10
  a[29] = 11
  a[30] = 12
  a[31] = 13
  a[32] = 14
  a[33] = 15
  a[34] = 16
  a[35] = 17
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
  a[35] = 43
  a[36] = 47
  a[37] = 51
  a[38] = 59
  a[39] = 67
  a[40] = 83
  a[41] = 99
  a[42] = 131
  a[43] = 259
  a[44] = 515
  a[45] = 1027
  a[46] = 2051
  a[47] = 4099
  a[48] = 8195
  a[49] = 16387
  a[50] = 32771
  a[51] = 65539
  a[52] = 131075
  a
}

///|
let ml_extra_bits : FixedArray[Int] = {
  let a = FixedArray::make(53, 0)
  // Codes 0-31: 0 extra bits
  a[32] = 1
  a[33] = 1
  a[34] = 1
  a[35] = 2
  a[36] = 2
  a[37] = 3
  a[38] = 3
  a[39] = 4
  a[40] = 4
  a[41] = 5
  a[42] = 7
  a[43] = 8
  a[44] = 9
  a[45] = 10
  a[46] = 11
  a[47] = 12
  a[48] = 13
  a[49] = 14
  a[50] = 15
  a[51] = 16
  a[52] = 17
  a
}
