///|
// Transform types from RFC 7932
const TRANSFORM_IDENTITY : Int = 0

///|
const TRANSFORM_OMIT_LAST_1 : Int = 1

///|
const TRANSFORM_OMIT_LAST_2 : Int = 2

///|
const TRANSFORM_OMIT_LAST_3 : Int = 3

///|
const TRANSFORM_OMIT_LAST_4 : Int = 4

///|
const TRANSFORM_OMIT_LAST_5 : Int = 5

///|
const TRANSFORM_OMIT_LAST_6 : Int = 6

///|
const TRANSFORM_OMIT_LAST_7 : Int = 7

///|
const TRANSFORM_OMIT_LAST_8 : Int = 8

///|
const TRANSFORM_OMIT_LAST_9 : Int = 9

///|
const TRANSFORM_UPPERCASE_FIRST : Int = 10

///|
const TRANSFORM_UPPERCASE_ALL : Int = 11

///|
const TRANSFORM_OMIT_FIRST_1 : Int = 12

///|
const TRANSFORM_OMIT_FIRST_2 : Int = 13

///|
const TRANSFORM_OMIT_FIRST_3 : Int = 14

///|
const TRANSFORM_OMIT_FIRST_4 : Int = 15

///|
const TRANSFORM_OMIT_FIRST_5 : Int = 16

///|
const TRANSFORM_OMIT_FIRST_6 : Int = 17

///|
const TRANSFORM_OMIT_FIRST_7 : Int = 18

///|
const TRANSFORM_OMIT_FIRST_8 : Int = 19

///|
const TRANSFORM_OMIT_FIRST_9 : Int = 20

///|
const NUM_TRANSFORMS : Int = 121

///|
// Prefix/suffix data from RFC 7932 transforms
// Each string is prefixed by its length byte.
let prefix_suffix_data : FixedArray[Byte] = [
  // 0x00: "\0"
  b'\x00',
  // 0x01: " " (1 byte)
  b'\x01', b'\x20',
  // 0x03: ", " (2 bytes)
  b'\x02', b'\x2C', b'\x20',
  // 0x06: " of the " (8 bytes)
  b'\x08', b'\x20', b'\x6F', b'\x66', b'\x20', b'\x74', b'\x68', b'\x65',
  b'\x20',
  // 0x0F: " of " (4 bytes)
  b'\x04', b'\x20', b'\x6F', b'\x66', b'\x20',
  // 0x14: "s " (2 bytes)
  b'\x02', b'\x73', b'\x20',
  // 0x17: "." (1 byte)
  b'\x01', b'\x2E',
  // 0x19: " and " (5 bytes)
  b'\x05', b'\x20', b'\x61', b'\x6E', b'\x64', b'\x20',
  // 0x1F: " in " (4 bytes)
  b'\x04', b'\x20', b'\x69', b'\x6E', b'\x20',
  // 0x24: "\"" (1 byte)
  b'\x01', b'\x22',
  // 0x26: " to " (4 bytes)
  b'\x04', b'\x20', b'\x74', b'\x6F', b'\x20',
  // 0x2B: "\">" (2 bytes)
  b'\x02', b'\x22', b'\x3E',
  // 0x2E: "\n" (1 byte)
  b'\x01', b'\x0A',
  // 0x30: ". " (2 bytes)
  b'\x02', b'\x2E', b'\x20',
  // 0x33: "]" (1 byte)
  b'\x01', b'\x5D',
  // 0x35: " for " (5 bytes)
  b'\x05', b'\x20', b'\x66', b'\x6F', b'\x72', b'\x20',
  // 0x3B: " a " (3 bytes)
  b'\x03', b'\x20', b'\x61', b'\x20',
  // 0x3F: " that " (6 bytes)
  b'\x06', b'\x20', b'\x74', b'\x68', b'\x61', b'\x74', b'\x20',
  // 0x46: "\'" (1 byte)
  b'\x01', b'\x27',
  // 0x48: " with " (6 bytes)
  b'\x06', b'\x20', b'\x77', b'\x69', b'\x74', b'\x68', b'\x20',
  // 0x4F: " from " (6 bytes)
  b'\x06', b'\x20', b'\x66', b'\x72', b'\x6F', b'\x6D', b'\x20',
  // 0x56: " by " (4 bytes)
  b'\x04', b'\x20', b'\x62', b'\x79', b'\x20',
  // 0x5B: "(" (1 byte)
  b'\x01', b'\x28',
  // 0x5D: ". The " (6 bytes)
  b'\x06', b'\x2E', b'\x20', b'\x54', b'\x68', b'\x65', b'\x20',
  // 0x64: " on " (4 bytes)
  b'\x04', b'\x20', b'\x6F', b'\x6E', b'\x20',
  // 0x69: " as " (4 bytes)
  b'\x04', b'\x20', b'\x61', b'\x73', b'\x20',
  // 0x6E: " is " (4 bytes)
  b'\x04', b'\x20', b'\x69', b'\x73', b'\x20',
  // 0x73: "ing " (4 bytes)
  b'\x04', b'\x69', b'\x6E', b'\x67', b'\x20',
  // 0x78: "\n\t" (2 bytes)
  b'\x02', b'\x0A', b'\x09',
  // 0x7B: ":" (1 byte)
  b'\x01', b'\x3A',
  // 0x7D: "ed " (3 bytes)
  b'\x03', b'\x65', b'\x64', b'\x20',
  // 0x81: "=\"" (2 bytes)
  b'\x02', b'\x3D', b'\x22',
  // 0x84: " at " (4 bytes)
  b'\x04', b'\x20', b'\x61', b'\x74', b'\x20',
  // 0x89: "ly " (3 bytes)
  b'\x03', b'\x6C', b'\x79', b'\x20',
  // 0x8D: "," (1 byte)
  b'\x01', b'\x2C',
  // 0x8F: "=\'" (2 bytes)
  b'\x02', b'\x3D', b'\x27',
  // 0x92: ".com/" (5 bytes)
  b'\x05', b'\x2E', b'\x63', b'\x6F', b'\x6D', b'\x2F',
  // 0x98: ". This " (7 bytes)
  b'\x07', b'\x2E', b'\x20', b'\x54', b'\x68', b'\x69', b'\x73', b'\x20',
  // 0xA0: " not " (5 bytes)
  b'\x05', b'\x20', b'\x6E', b'\x6F', b'\x74', b'\x20',
  // 0xA6: "er " (3 bytes)
  b'\x03', b'\x65', b'\x72', b'\x20',
  // 0xAA: "al " (3 bytes)
  b'\x03', b'\x61', b'\x6C', b'\x20',
  // 0xAE: "ful " (4 bytes)
  b'\x04', b'\x66', b'\x75', b'\x6C', b'\x20',
  // 0xB3: "ive " (4 bytes)
  b'\x04', b'\x69', b'\x76', b'\x65', b'\x20',
  // 0xB8: "less " (5 bytes)
  b'\x05', b'\x6C', b'\x65', b'\x73', b'\x73', b'\x20',
  // 0xBE: "est " (4 bytes)
  b'\x04', b'\x65', b'\x73', b'\x74', b'\x20',
  // 0xC3: "ize " (4 bytes)
  b'\x04', b'\x69', b'\x7A', b'\x65', b'\x20',
  // 0xC8: "\xc2\xa0" (2 bytes - NBSP in UTF-8)
  b'\x02', b'\xC2', b'\xA0',
  // 0xCB: "ous " (4 bytes)
  b'\x04', b'\x6F', b'\x75', b'\x73', b'\x20',
  // 0xD0: " the " (5 bytes)
  b'\x05', b'\x20', b'\x74', b'\x68', b'\x65', b'\x20',
  // 0xD6: "e " (2 bytes)
  b'\x02', b'\x65', b'\x20',
]

///|
// Map from prefix/suffix index to offset in prefix_suffix_data
let prefix_suffix_map : FixedArray[Int] = [
  0x00, 0x01, 0x03, 0x06, 0x0F, 0x14, 0x17, 0x19, 0x1F, 0x24, 0x26, 0x2B,
  0x2E, 0x30, 0x33, 0x35, 0x3B, 0x3F, 0x46, 0x48, 0x4F, 0x56, 0x5B, 0x5D,
  0x64, 0x69, 0x6E, 0x73, 0x78, 0x7B, 0x7D, 0x81, 0x84, 0x89, 0x8D, 0x8F,
  0x92, 0x98, 0xA0, 0xA6, 0xAA, 0xAE, 0xB3, 0xB8, 0xBE, 0xC3, 0xC8, 0xCB,
  0xD0, 0xD6,
]

///|
// Transform data: 121 transforms, each 3 bytes: (prefix_id, transform_type, suffix_id)
// prefix_id and suffix_id index into prefix_suffix_map
let transforms_data : FixedArray[Int] = [
  // Transform 0-9
  49, TRANSFORM_IDENTITY, 49,
  49, TRANSFORM_IDENTITY, 0,
   0, TRANSFORM_IDENTITY, 0,
  49, TRANSFORM_OMIT_FIRST_1, 49,
  49, TRANSFORM_UPPERCASE_FIRST, 0,
  49, TRANSFORM_IDENTITY, 47,
   0, TRANSFORM_IDENTITY, 49,
   4, TRANSFORM_IDENTITY, 0,
  49, TRANSFORM_IDENTITY, 3,
  49, TRANSFORM_UPPERCASE_FIRST, 49,
  // Transform 10-19
  49, TRANSFORM_IDENTITY, 6,
  49, TRANSFORM_OMIT_FIRST_2, 49,
  49, TRANSFORM_OMIT_LAST_1, 49,
   1, TRANSFORM_IDENTITY, 0,
  49, TRANSFORM_IDENTITY, 1,
   0, TRANSFORM_UPPERCASE_FIRST, 0,
  49, TRANSFORM_IDENTITY, 7,
  49, TRANSFORM_IDENTITY, 9,
  48, TRANSFORM_IDENTITY, 0,
  49, TRANSFORM_IDENTITY, 8,
  // Transform 20-29
  49, TRANSFORM_IDENTITY, 5,
  49, TRANSFORM_IDENTITY, 10,
  49, TRANSFORM_IDENTITY, 11,
  49, TRANSFORM_OMIT_LAST_3, 49,
  49, TRANSFORM_IDENTITY, 13,
  49, TRANSFORM_IDENTITY, 14,
  49, TRANSFORM_OMIT_FIRST_3, 49,
  49, TRANSFORM_OMIT_LAST_2, 49,
  49, TRANSFORM_IDENTITY, 15,
  49, TRANSFORM_IDENTITY, 16,
  // Transform 30-39
   0, TRANSFORM_UPPERCASE_FIRST, 49,
  49, TRANSFORM_IDENTITY, 12,
   5, TRANSFORM_IDENTITY, 49,
   0, TRANSFORM_IDENTITY, 1,
  49, TRANSFORM_OMIT_FIRST_4, 49,
  49, TRANSFORM_IDENTITY, 18,
  49, TRANSFORM_IDENTITY, 17,
  49, TRANSFORM_IDENTITY, 19,
  49, TRANSFORM_IDENTITY, 20,
  49, TRANSFORM_OMIT_FIRST_5, 49,
  // Transform 40-49
  49, TRANSFORM_OMIT_FIRST_6, 49,
  47, TRANSFORM_IDENTITY, 49,
  49, TRANSFORM_OMIT_LAST_4, 49,
  49, TRANSFORM_IDENTITY, 22,
  49, TRANSFORM_UPPERCASE_ALL, 49,
  49, TRANSFORM_IDENTITY, 23,
  49, TRANSFORM_IDENTITY, 24,
  49, TRANSFORM_IDENTITY, 25,
  49, TRANSFORM_OMIT_LAST_7, 49,
  49, TRANSFORM_OMIT_LAST_1, 26,
  // Transform 50-59
  49, TRANSFORM_IDENTITY, 27,
  49, TRANSFORM_IDENTITY, 28,
   0, TRANSFORM_IDENTITY, 12,
  49, TRANSFORM_IDENTITY, 29,
  49, TRANSFORM_OMIT_FIRST_9, 49,
  49, TRANSFORM_OMIT_FIRST_7, 49,
  49, TRANSFORM_OMIT_LAST_6, 49,
  49, TRANSFORM_IDENTITY, 21,
  49, TRANSFORM_UPPERCASE_FIRST, 1,
  49, TRANSFORM_OMIT_LAST_8, 49,
  // Transform 60-69
  49, TRANSFORM_IDENTITY, 31,
  49, TRANSFORM_IDENTITY, 32,
  47, TRANSFORM_IDENTITY, 3,
  49, TRANSFORM_OMIT_LAST_5, 49,
  49, TRANSFORM_OMIT_LAST_9, 49,
   0, TRANSFORM_UPPERCASE_FIRST, 1,
  49, TRANSFORM_UPPERCASE_FIRST, 8,
   5, TRANSFORM_IDENTITY, 21,
  49, TRANSFORM_UPPERCASE_ALL, 0,
  49, TRANSFORM_UPPERCASE_FIRST, 10,
  // Transform 70-79
  49, TRANSFORM_IDENTITY, 30,
   0, TRANSFORM_IDENTITY, 5,
  35, TRANSFORM_IDENTITY, 49,
  47, TRANSFORM_IDENTITY, 2,
  49, TRANSFORM_UPPERCASE_FIRST, 17,
  49, TRANSFORM_IDENTITY, 36,
  49, TRANSFORM_IDENTITY, 33,
   5, TRANSFORM_IDENTITY, 0,
  49, TRANSFORM_UPPERCASE_FIRST, 21,
  49, TRANSFORM_UPPERCASE_FIRST, 5,
  // Transform 80-89
  49, TRANSFORM_IDENTITY, 37,
   0, TRANSFORM_IDENTITY, 30,
  49, TRANSFORM_IDENTITY, 38,
   0, TRANSFORM_UPPERCASE_ALL, 0,
  49, TRANSFORM_IDENTITY, 39,
   0, TRANSFORM_UPPERCASE_ALL, 49,
  49, TRANSFORM_IDENTITY, 34,
  49, TRANSFORM_UPPERCASE_ALL, 8,
  49, TRANSFORM_UPPERCASE_FIRST, 12,
   0, TRANSFORM_IDENTITY, 21,
  // Transform 90-99
  49, TRANSFORM_IDENTITY, 40,
   0, TRANSFORM_UPPERCASE_FIRST, 12,
  49, TRANSFORM_IDENTITY, 41,
  49, TRANSFORM_IDENTITY, 42,
  49, TRANSFORM_UPPERCASE_ALL, 17,
  49, TRANSFORM_IDENTITY, 43,
   0, TRANSFORM_UPPERCASE_FIRST, 5,
  49, TRANSFORM_UPPERCASE_ALL, 10,
   0, TRANSFORM_IDENTITY, 34,
  49, TRANSFORM_UPPERCASE_FIRST, 33,
  // Transform 100-109
  49, TRANSFORM_IDENTITY, 44,
  49, TRANSFORM_UPPERCASE_ALL, 5,
  45, TRANSFORM_IDENTITY, 49,
   0, TRANSFORM_IDENTITY, 33,
  49, TRANSFORM_UPPERCASE_FIRST, 30,
  49, TRANSFORM_UPPERCASE_ALL, 30,
  49, TRANSFORM_IDENTITY, 46,
  49, TRANSFORM_UPPERCASE_ALL, 1,
  49, TRANSFORM_UPPERCASE_FIRST, 34,
   0, TRANSFORM_UPPERCASE_FIRST, 33,
  // Transform 110-120
   0, TRANSFORM_UPPERCASE_ALL, 30,
   0, TRANSFORM_UPPERCASE_ALL, 1,
  49, TRANSFORM_UPPERCASE_ALL, 33,
  49, TRANSFORM_UPPERCASE_ALL, 21,
  49, TRANSFORM_UPPERCASE_ALL, 12,
   0, TRANSFORM_UPPERCASE_ALL, 5,
  49, TRANSFORM_UPPERCASE_ALL, 34,
   0, TRANSFORM_UPPERCASE_ALL, 12,
   0, TRANSFORM_UPPERCASE_FIRST, 30,
   0, TRANSFORM_UPPERCASE_ALL, 34,
   0, TRANSFORM_UPPERCASE_FIRST, 34,
]

///|
// cutOffTransforms[0] is the transform index for identity with no prefix/suffix
// Used for fast-path when transform is identity
let cut_off_transforms : FixedArray[Int] = [0, 12, 27, 23, 42, 63, 56, 48, 59, 64]

///|
fn to_upper_case(dst : FixedArray[Byte], pos : Int) -> Int {
  let p0 = dst[pos].to_int()
  if p0 < 0xC0 {
    if p0 >= 0x61 && p0 <= 0x7A { // 'a'..'z'
      dst[pos] = (p0 ^ 32).to_byte()
    }
    return 1
  }
  if p0 < 0xE0 {
    if pos + 1 < dst.length() {
      dst[pos + 1] = (dst[pos + 1].to_int() ^ 32).to_byte()
    }
    return 2
  }
  // 3-byte character
  if pos + 2 < dst.length() {
    dst[pos + 2] = (dst[pos + 2].to_int() ^ 5).to_byte()
  }
  3
}

///|
/// Apply a dictionary word transform, writing result to dst starting at dst_pos.
/// Returns the number of bytes written.
fn transform_dictionary_word(
  dst : FixedArray[Byte],
  dst_pos : Int,
  word : FixedArray[Byte],
  word_offset : Int,
  word_len : Int,
  transform_idx : Int,
) -> Int {
  let ti = transform_idx * 3
  let prefix_id = transforms_data[ti]
  let transform_type = transforms_data[ti + 1]
  let suffix_id = transforms_data[ti + 2]
  let mut idx = dst_pos
  // Write prefix
  if prefix_id != 49 {
    // prefix_id 49 means empty prefix (index 49 in map -> offset 0xD6 -> "e " but wait...)
    // Actually, 49 maps to prefix_suffix_map[49] which is the last entry
    // Let's just handle it generically
    let offset = prefix_suffix_map[prefix_id]
    let len = prefix_suffix_data[offset].to_int()
    for i in 0..<len {
      dst[idx] = prefix_suffix_data[offset + 1 + i]
      idx += 1
    }
  } else {
    // prefix_id 49 -> empty string (the map value 0xD6 points to "e " but that's suffix_id 49)
    // Actually prefix_suffix_map[49] = 0xD6, prefix_suffix_data[0xD6] = 0x02 (length 2), then 'e', ' '
    let offset = prefix_suffix_map[49]
    let len = prefix_suffix_data[offset].to_int()
    for i in 0..<len {
      dst[idx] = prefix_suffix_data[offset + 1 + i]
      idx += 1
    }
  }
  // Apply transform to word
  let mut effective_len = word_len
  let mut effective_offset = word_offset
  if transform_type <= TRANSFORM_OMIT_LAST_9 {
    effective_len -= transform_type
    if effective_len < 0 {
      effective_len = 0
    }
  } else if transform_type >= TRANSFORM_OMIT_FIRST_1 &&
    transform_type <= TRANSFORM_OMIT_FIRST_9 {
    let skip = transform_type - TRANSFORM_OMIT_FIRST_1 + 1
    effective_offset += skip
    effective_len -= skip
    if effective_len < 0 {
      effective_len = 0
    }
  }
  let word_start = idx
  for i in 0..<effective_len {
    dst[idx] = word[effective_offset + i]
    idx += 1
  }
  // Apply uppercase transforms
  if transform_type == TRANSFORM_UPPERCASE_FIRST {
    if effective_len > 0 {
      to_upper_case(dst, word_start) |> ignore
    }
  } else if transform_type == TRANSFORM_UPPERCASE_ALL {
    let mut pos = word_start
    let mut remaining = effective_len
    while remaining > 0 {
      let step = to_upper_case(dst, pos)
      pos += step
      remaining -= step
    }
  }
  // Write suffix
  let s_offset = prefix_suffix_map[suffix_id]
  let s_len = prefix_suffix_data[s_offset].to_int()
  for i in 0..<s_len {
    dst[idx] = prefix_suffix_data[s_offset + 1 + i]
    idx += 1
  }
  idx - dst_pos
}
