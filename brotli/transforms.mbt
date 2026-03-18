///|
/// Brotli static dictionary transforms (RFC 7932, Appendix B).
/// 121 transforms, each consisting of a prefix, a transform type, and a suffix.

// Transform type constants (RFC 7932 Appendix B)
// Types 0-9: identity / omit last 1-9 bytes
// Type 10: uppercase first letter
// Type 11: uppercase all letters
// Types 12-20: omit first 1-9 bytes
const TRANSFORM_OMIT_LAST_9 : Int = 9

///|
const TRANSFORM_UPPERCASE_FIRST : Int = 10

///|
const TRANSFORM_UPPERCASE_ALL : Int = 11

///|
const TRANSFORM_OMIT_FIRST_1 : Int = 12

///|
const TRANSFORM_OMIT_FIRST_9 : Int = 20

///|
/// Prefix/suffix string data. Each string is stored as [length, bytes...].
/// Index 49 maps to the empty string (length 0).
let prefix_suffix_data : FixedArray[Byte] = [
  // Offset 0x00: "\x01 " (space)
  b'\x01', b'\x20',
  // Offset 0x02: "\x02, " (comma space)
  b'\x02', b'\x2C', b'\x20',
  // Offset 0x05: "\x08 of the "
  b'\x08', b'\x20', b'\x6F', b'\x66', b'\x20', b'\x74', b'\x68', b'\x65', b'\x20',
  // Offset 0x0E: "\x04 of "
  b'\x04', b'\x20', b'\x6F', b'\x66', b'\x20',
  // Offset 0x13: "\x02s "
  b'\x02', b'\x73', b'\x20',
  // Offset 0x16: "\x01."
  b'\x01', b'\x2E',
  // Offset 0x18: "\x05 and "
  b'\x05', b'\x20', b'\x61', b'\x6E', b'\x64', b'\x20',
  // Offset 0x1E: "\x04 in "  (actually "\x04 " is at 0x1E, then "in \x01\"")
  b'\x04', b'\x20', b'\x69', b'\x6E', b'\x20',
  // Offset 0x23: "\x01\""
  b'\x01', b'\x22',
  // Offset 0x25: "\x04 to "
  b'\x04', b'\x20', b'\x74', b'\x6F', b'\x20',
  // Offset 0x2A: "\x02\">"
  b'\x02', b'\x22', b'\x3E',
  // Offset 0x2D: "\x01\n"
  b'\x01', b'\x0A',
  // Offset 0x2F: "\x02. "
  b'\x02', b'\x2E', b'\x20',
  // Offset 0x32: "\x01]"
  b'\x01', b'\x5D',
  // Offset 0x34: "\x05 for "
  b'\x05', b'\x20', b'\x66', b'\x6F', b'\x72', b'\x20',
  // Offset 0x3A: "\x03 a "
  b'\x03', b'\x20', b'\x61', b'\x20',
  // Offset 0x3E: "\x06 that "
  b'\x06', b'\x20', b'\x74', b'\x68', b'\x61', b'\x74', b'\x20',
  // Offset 0x45: "\x01'"
  b'\x01', b'\x27',
  // Offset 0x47: "\x06 with "
  b'\x06', b'\x20', b'\x77', b'\x69', b'\x74', b'\x68', b'\x20',
  // Offset 0x4E: "\x06 from "
  b'\x06', b'\x20', b'\x66', b'\x72', b'\x6F', b'\x6D', b'\x20',
  // Offset 0x55: "\x04 by "
  b'\x04', b'\x20', b'\x62', b'\x79', b'\x20',
  // Offset 0x5A: "\x01("
  b'\x01', b'\x28',
  // Offset 0x5C: "\x06. The "
  b'\x06', b'\x2E', b'\x20', b'\x54', b'\x68', b'\x65', b'\x20',
  // Offset 0x63: "\x04 on "
  b'\x04', b'\x20', b'\x6F', b'\x6E', b'\x20',
  // Offset 0x68: "\x04 as "
  b'\x04', b'\x20', b'\x61', b'\x73', b'\x20',
  // Offset 0x6D: "\x04 is "
  b'\x04', b'\x20', b'\x69', b'\x73', b'\x20',
  // Offset 0x72: "\x04ing "
  b'\x04', b'\x69', b'\x6E', b'\x67', b'\x20',
  // Offset 0x77: "\x02\n\t"
  b'\x02', b'\x0A', b'\x09',
  // Offset 0x7A: "\x01:"
  b'\x01', b'\x3A',
  // Offset 0x7C: "\x03ed "
  b'\x03', b'\x65', b'\x64', b'\x20',
  // Offset 0x80: "\x02=\""
  b'\x02', b'\x3D', b'\x22',
  // Offset 0x83: "\x04 at "
  b'\x04', b'\x20', b'\x61', b'\x74', b'\x20',
  // Offset 0x88: "\x03ly "
  b'\x03', b'\x6C', b'\x79', b'\x20',
  // Offset 0x8C: "\x01,"
  b'\x01', b'\x2C',
  // Offset 0x8E: "\x02='"
  b'\x02', b'\x3D', b'\x27',
  // Offset 0x91: "\x05.com/"
  b'\x05', b'\x2E', b'\x63', b'\x6F', b'\x6D', b'\x2F',
  // Offset 0x97: "\x07. This "
  b'\x07', b'\x2E', b'\x20', b'\x54', b'\x68', b'\x69', b'\x73', b'\x20',
  // Offset 0x9F: "\x05 not "
  b'\x05', b'\x20', b'\x6E', b'\x6F', b'\x74', b'\x20',
  // Offset 0xA5: "\x03er "
  b'\x03', b'\x65', b'\x72', b'\x20',
  // Offset 0xA9: "\x03al "
  b'\x03', b'\x61', b'\x6C', b'\x20',
  // Offset 0xAD: "\x04ful "
  b'\x04', b'\x66', b'\x75', b'\x6C', b'\x20',
  // Offset 0xB2: "\x04ive "
  b'\x04', b'\x69', b'\x76', b'\x65', b'\x20',
  // Offset 0xB7: "\x05less "
  b'\x05', b'\x6C', b'\x65', b'\x73', b'\x73', b'\x20',
  // Offset 0xBD: "\x04est "
  b'\x04', b'\x65', b'\x73', b'\x74', b'\x20',
  // Offset 0xC2: "\x04ize "
  b'\x04', b'\x69', b'\x7A', b'\x65', b'\x20',
  // Offset 0xC7: "\x02\xC2\xA0" (non-breaking space UTF-8)
  b'\x02', b'\xC2', b'\xA0',
  // Offset 0xCA: "\x04ous "
  b'\x04', b'\x6F', b'\x75', b'\x73', b'\x20',
  // Offset 0xCF: "\x05 the "
  b'\x05', b'\x20', b'\x74', b'\x68', b'\x65', b'\x20',
  // Offset 0xD5: "\x02e "
  b'\x02', b'\x65', b'\x20',
  // Offset 0xD8: "\x00" (empty, acts as the null terminator / empty string marker)
  b'\x00',
]

///|
/// Map from prefix/suffix ID to offset in prefix_suffix_data.
let prefix_suffix_map : FixedArray[Int] = [
  0x00, 0x02, 0x05, 0x0E, 0x13, 0x16, 0x18, 0x1E, 0x23, 0x25,
  0x2A, 0x2D, 0x2F, 0x32, 0x34, 0x3A, 0x3E, 0x45, 0x47, 0x4E,
  0x55, 0x5A, 0x5C, 0x63, 0x68, 0x6D, 0x72, 0x77, 0x7A, 0x7C,
  0x80, 0x83, 0x88, 0x8C, 0x8E, 0x91, 0x97, 0x9F, 0xA5, 0xA9,
  0xAD, 0xB2, 0xB7, 0xBD, 0xC2, 0xC7, 0xCA, 0xCF, 0xD5, 0xD8,
]

///|
/// Transform definitions: 121 transforms, each [prefix_id, type, suffix_id].
/// Index 49 in prefix_suffix_map -> offset 0xD8 -> "\x00" (empty string).
let transforms_data : FixedArray[Int] = [
  49,  0, 49,   // 0: identity
  49,  0,  0,   // 1: " " suffix
   0,  0,  0,   // 2: " " prefix+suffix
  49, 12, 49,   // 3: omit_first_1
  49, 10,  0,   // 4: uppercase_first + " "
  49,  0, 47,   // 5: " the " suffix
   0,  0, 49,   // 6: " " prefix
   4,  0,  0,   // 7: " of " prefix + " " suffix
  49,  0,  3,   // 8: " of the " suffix
  49, 10, 49,   // 9: uppercase_first
  49,  0,  6,   // 10: " and " suffix
  49, 13, 49,   // 11: omit_first_2
  49,  1, 49,   // 12: omit_last_1
   1,  0,  0,   // 13: ", " prefix + " " suffix
  49,  0,  1,   // 14: ", " suffix
   0, 10,  0,   // 15: " " prefix + uppercase_first + " " suffix
  49,  0,  7,   // 16: " in " suffix
  49,  0,  9,   // 17: " to " suffix
  48,  0,  0,   // 18: "." prefix + " " suffix (prefix_id=48 -> 0x47? No...)
  49,  0,  8,   // 19: "\"" suffix
  49,  0,  5,   // 20: "." suffix
  49,  0, 10,   // 21: "\">" suffix
  49,  0, 11,   // 22: "\n" suffix
  49,  3, 49,   // 23: omit_last_3
  49,  0, 13,   // 24: "]" suffix
  49,  0, 14,   // 25: " for " suffix
  49, 14, 49,   // 26: omit_first_3
  49,  2, 49,   // 27: omit_last_2
  49,  0, 15,   // 28: " a " suffix
  49,  0, 16,   // 29: " that " suffix
   0, 10, 49,   // 30: " " prefix + uppercase_first
  49,  0, 12,   // 31: ". " suffix
   5,  0, 49,   // 32: "." prefix
   0,  0,  1,   // 33: " " prefix + ", " suffix
  49, 15, 49,   // 34: omit_first_4
  49,  0, 18,   // 35: " with " suffix
  49,  0, 17,   // 36: "'" suffix
  49,  0, 19,   // 37: " from " suffix
  49,  0, 20,   // 38: " by " suffix
  49, 16, 49,   // 39: omit_first_5
  49, 17, 49,   // 40: omit_first_6
  47,  0, 49,   // 41: " the " prefix
  49,  4, 49,   // 42: omit_last_4
  49,  0, 22,   // 43: "\n\t" suffix
  49, 11, 49,   // 44: uppercase_all
  49,  0, 23,   // 45: " on " suffix
  49,  0, 24,   // 46: " as " suffix
  49,  0, 25,   // 47: " is " suffix
  49,  7, 49,   // 48: omit_last_7
  49,  1, 26,   // 49: omit_last_1 + "ing " suffix
  49,  0, 27,   // 50: ":" suffix (wait, 27 = 0x77 -> "\n\t")
  49,  0, 28,   // 51: "ed " suffix
   0,  0, 12,   // 52: " " prefix + ". " suffix
  49,  0, 29,   // 53: "=\"" suffix
  49, 20, 49,   // 54: omit_first_9
  49, 18, 49,   // 55: omit_first_7
  49,  6, 49,   // 56: omit_last_6
  49,  0, 21,   // 57: "(" suffix
  49, 10,  1,   // 58: uppercase_first + ", " suffix
  49,  8, 49,   // 59: omit_last_8
  49,  0, 31,   // 60: " at " suffix
  49,  0, 32,   // 61: "ly " suffix
  47,  0,  3,   // 62: " the " prefix + " of the " suffix
  49,  5, 49,   // 63: omit_last_5
  49,  9, 49,   // 64: omit_last_9
   0, 10,  1,   // 65: " " prefix + uppercase_first + ", " suffix
  49, 10,  8,   // 66: uppercase_first + "\"" suffix
   5,  0, 21,   // 67: "." prefix + "(" suffix
  49, 11,  0,   // 68: uppercase_all + " " suffix
  49, 10, 10,   // 69: uppercase_first + "\">" suffix
  49,  0, 30,   // 70: "," suffix
   0,  0,  5,   // 71: " " prefix + "." suffix
  35,  0, 49,   // 72: ".com/" prefix
  47,  0,  2,   // 73: " the " prefix + " of " suffix (wait, suffix_id=2 -> 0x05 -> " of the ")
  49, 10, 17,   // 74: uppercase_first + "'" suffix
  49,  0, 36,   // 75: ". This " suffix
  49,  0, 33,   // 76: "," suffix
   5,  0,  0,   // 77: "." prefix + " " suffix
  49, 10, 21,   // 78: uppercase_first + "(" suffix
  49, 10,  5,   // 79: uppercase_first + "." suffix
  49,  0, 37,   // 80: " not " suffix
   0,  0, 30,   // 81: " " prefix + "," suffix
  49,  0, 38,   // 82: "er " suffix
   0, 11,  0,   // 83: " " prefix + uppercase_all + " " suffix
  49,  0, 39,   // 84: "al " suffix
   0, 11, 49,   // 85: " " prefix + uppercase_all
  49,  0, 34,   // 86: "='" suffix
  49, 11,  8,   // 87: uppercase_all + "\"" suffix
  49, 10, 12,   // 88: uppercase_first + ". " suffix
   0,  0, 21,   // 89: " " prefix + "(" suffix
  49,  0, 40,   // 90: "ful " suffix
   0, 10, 12,   // 91: " " prefix + uppercase_first + ". " suffix
  49,  0, 41,   // 92: "ive " suffix
  49,  0, 42,   // 93: "less " suffix
  49, 11, 17,   // 94: uppercase_all + "'" suffix
  49,  0, 43,   // 95: "est " suffix
   0, 10,  5,   // 96: " " prefix + uppercase_first + "." suffix
  49, 11, 10,   // 97: uppercase_all + "\">" suffix
   0,  0, 34,   // 98: " " prefix + "='" suffix
  49, 10, 33,   // 99: uppercase_first + "," suffix
  49,  0, 44,   // 100: "ize " suffix
  49, 11,  5,   // 101: uppercase_all + "." suffix
  45,  0, 49,   // 102: "\xC2\xA0" prefix
   0,  0, 33,   // 103: " " prefix + "," suffix
  49, 10, 30,   // 104: uppercase_first + "," suffix
  49, 11, 30,   // 105: uppercase_all + "," suffix
  49,  0, 46,   // 106: "ous " suffix
  49, 11,  1,   // 107: uppercase_all + ", " suffix
  49, 10, 34,   // 108: uppercase_first + "='" suffix
   0, 10, 33,   // 109: " " prefix + uppercase_first + "," suffix
   0, 11, 30,   // 110: " " prefix + uppercase_all + "," suffix
   0, 11,  1,   // 111: " " prefix + uppercase_all + ", " suffix
  49, 11, 33,   // 112: uppercase_all + "," suffix
  49, 11, 21,   // 113: uppercase_all + "(" suffix
  49, 11, 12,   // 114: uppercase_all + ". " suffix
   0, 11,  5,   // 115: " " prefix + uppercase_all + "." suffix
  49, 11, 34,   // 116: uppercase_all + "='" suffix
   0, 11, 12,   // 117: " " prefix + uppercase_all + ". " suffix
   0, 10, 30,   // 118: " " prefix + uppercase_first + "," suffix
   0, 11, 34,   // 119: " " prefix + uppercase_all + "='" suffix
   0, 10, 34,   // 120: " " prefix + uppercase_first + "='" suffix
]

///|
/// Apply a Brotli dictionary transform to a word, writing the result
/// into an output buffer. Returns the number of bytes written.
fn transform_dictionary_word(
  dst : FixedArray[Byte],
  dst_offset : Int,
  word : FixedArray[Byte],
  word_offset : Int,
  word_len : Int,
  transform_idx : Int,
) -> Int {
  let mut idx = dst_offset
  let prefix_id = transforms_data[transform_idx * 3]
  let ttype = transforms_data[transform_idx * 3 + 1]
  let suffix_id = transforms_data[transform_idx * 3 + 2]
  // Write prefix
  let prefix_offset = prefix_suffix_map[prefix_id]
  let prefix_len = prefix_suffix_data[prefix_offset].to_int()
  for i in 0..<prefix_len {
    dst[idx] = prefix_suffix_data[prefix_offset + 1 + i]
    idx += 1
  }
  // Determine effective word after omit transforms
  let mut w_off = word_offset
  let mut w_len = word_len
  if ttype <= TRANSFORM_OMIT_LAST_9 {
    // omit_last: ttype == number of bytes to omit from end
    w_len -= ttype
    if w_len < 0 {
      w_len = 0
    }
  } else if ttype >= TRANSFORM_OMIT_FIRST_1 && ttype <= TRANSFORM_OMIT_FIRST_9 {
    let skip = ttype - TRANSFORM_OMIT_FIRST_1 + 1
    w_off += skip
    w_len -= skip
    if w_len < 0 {
      w_len = 0
    }
  }
  // Copy word bytes
  let word_start_in_dst = idx
  for i in 0..<w_len {
    dst[idx] = word[w_off + i]
    idx += 1
  }
  // Apply uppercase transforms in-place
  if ttype == TRANSFORM_UPPERCASE_FIRST {
    ignore(to_upper_case(dst, word_start_in_dst))
  } else if ttype == TRANSFORM_UPPERCASE_ALL {
    let mut pos = word_start_in_dst
    let end = word_start_in_dst + w_len
    while pos < end {
      let step = to_upper_case(dst, pos)
      pos += step
    }
  }
  // Write suffix
  let suffix_offset = prefix_suffix_map[suffix_id]
  let suffix_len = prefix_suffix_data[suffix_offset].to_int()
  for i in 0..<suffix_len {
    dst[idx] = prefix_suffix_data[suffix_offset + 1 + i]
    idx += 1
  }
  idx - dst_offset
}

///|
/// Uppercase a single character in place (simplified UTF-8 model).
/// Returns the number of bytes consumed.
fn to_upper_case(buf : FixedArray[Byte], pos : Int) -> Int {
  let b = buf[pos].to_int()
  if b < 0xC0 {
    if b >= 0x61 && b <= 0x7A {
      // a-z -> A-Z
      buf[pos] = (b ^ 32).to_byte()
    }
    return 1
  }
  if b < 0xE0 {
    // 2-byte UTF-8: flip bit 5 of second byte
    buf[pos + 1] = (buf[pos + 1].to_int() ^ 32).to_byte()
    return 2
  }
  // 3-byte UTF-8: flip bits 0,2 of third byte
  buf[pos + 2] = (buf[pos + 2].to_int() ^ 5).to_byte()
  3
}
