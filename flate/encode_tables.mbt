///|
/// Precomputed reversed fixed Huffman literal codes.
/// Entry format: (reversed_code << 4) | code_length
let fixed_lit_codes : FixedArray[UInt] = {
  let t = FixedArray::make(286, 0U)
  for sym in 0..<=143 {
    let code = sym + 0x30
    t[sym] = (reverse_uint_8(code.reinterpret_as_uint()) << 4) | 8U
  }
  for sym in 144..<=255 {
    let code = sym - 144 + 0x190
    t[sym] = (reverse_uint_9(code.reinterpret_as_uint()) << 4) | 9U
  }
  for sym in 256..<=279 {
    let code = sym - 256
    t[sym] = (reverse_uint_7(code.reinterpret_as_uint()) << 4) | 7U
  }
  for sym in 280..<=285 {
    let code = sym - 280 + 0xC0
    t[sym] = (reverse_uint_8(code.reinterpret_as_uint()) << 4) | 8U
  }
  t
}

///|
let fixed_dist_codes : FixedArray[UInt] = {
  let t = FixedArray::make(30, 0U)
  for i in 0..<30 {
    t[i] = reverse_uint_5(i.reinterpret_as_uint())
  }
  t
}

///|
let length_encode_table : FixedArray[Int] = {
  let size = MAX_MATCH_LENGTH - MIN_MATCH_LENGTH + 1
  let t = FixedArray::make(size * 3, 0)
  for length in MIN_MATCH_LENGTH..<=MAX_MATCH_LENGTH {
    let idx = length - MIN_MATCH_LENGTH
    let mut found = false
    for i in 0..<length_base.length() {
      let next_base = if i + 1 < length_base.length() {
        length_base[i + 1]
      } else {
        259
      }
      if length >= length_base[i] && length < next_base {
        t[idx * 3] = 257 + i
        t[idx * 3 + 1] = length_extra[i]
        t[idx * 3 + 2] = length - length_base[i]
        found = true
        break
      }
    }
    if !found {
      t[idx * 3] = 285
      t[idx * 3 + 1] = 0
      t[idx * 3 + 2] = 0
    }
  }
  t
}

///|
let dist_encode_table : FixedArray[Int] = {
  let size = MAX_MATCH_OFFSET
  let t = FixedArray::make(size * 2, 0)
  for d in 1..<=MAX_MATCH_OFFSET {
    for i in 0..<dist_base.length() {
      let next_base = if i + 1 < dist_base.length() {
        dist_base[i + 1]
      } else {
        32769
      }
      if d >= dist_base[i] && d < next_base {
        t[(d - 1) * 2] = i
        t[(d - 1) * 2 + 1] = dist_extra[i]
        break
      }
    }
  }
  t
}

///|
fn reverse_uint_5(val : UInt) -> UInt {
  let mut result = 0U
  let mut v = val
  result = (result << 1) | (v & 1U)
  v = v >> 1
  result = (result << 1) | (v & 1U)
  v = v >> 1
  result = (result << 1) | (v & 1U)
  v = v >> 1
  result = (result << 1) | (v & 1U)
  v = v >> 1
  result = (result << 1) | (v & 1U)
  ignore(v)
  result
}

///|
fn reverse_uint_7(val : UInt) -> UInt {
  let (result, _) = for result = 0U, v = val, i = 0; i < 7; {
    continue (result << 1) | (v & 1U), v >> 1, i + 1
  } nobreak {
    (result, val)
  }
  result
}

///|
fn reverse_uint_8(val : UInt) -> UInt {
  let (result, _) = for result = 0U, v = val, i = 0; i < 8; {
    continue (result << 1) | (v & 1U), v >> 1, i + 1
  } nobreak {
    (result, val)
  }
  result
}

///|
fn reverse_uint_9(val : UInt) -> UInt {
  let (result, _) = for result = 0U, v = val, i = 0; i < 9; {
    continue (result << 1) | (v & 1U), v >> 1, i + 1
  } nobreak {
    (result, val)
  }
  result
}
