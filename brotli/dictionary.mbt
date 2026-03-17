///|
// Brotli static dictionary metadata (RFC 7932)

const MIN_DICTIONARY_WORD_LENGTH : Int = 4

///|
const MAX_DICTIONARY_WORD_LENGTH : Int = 24

///|
// Number of bits to encode word index for each word length (0-31).
// Words exist for lengths 4-24 only.
let dict_size_bits_by_length : FixedArray[Int] = [
  0, 0, 0, 0, 10, 10, 11, 11,
  10, 10, 10, 10, 10, 9, 9, 8,
  7, 7, 8, 7, 7, 6, 6, 5,
  5, 0, 0, 0, 0, 0, 0, 0,
]

///|
// Byte offset into dictionary data for each word length.
let dict_offsets_by_length : FixedArray[Int] = [
  0, 0, 0, 0, 0, 4096, 9216, 21504,
  35840, 44032, 53248, 63488, 74752, 87040, 93696, 100864,
  104704, 106752, 108928, 113536, 115968, 118528, 119872, 121280,
  122016, 122784, 122784, 122784, 122784, 122784, 122784, 122784,
]

///|
/// Look up a dictionary word by length and index.
/// Returns (offset, length) into brotli_dict_data, or (-1, 0) if invalid.
fn dictionary_word(word_length : Int, word_idx : Int) -> (Int, Int) {
  if word_length < MIN_DICTIONARY_WORD_LENGTH ||
    word_length > MAX_DICTIONARY_WORD_LENGTH {
    return (-1, 0)
  }
  let size_bits = dict_size_bits_by_length[word_length]
  if size_bits == 0 {
    return (-1, 0)
  }
  let mask = (1 << size_bits) - 1
  let idx = word_idx & mask
  let offset = dict_offsets_by_length[word_length] + idx * word_length
  (offset, word_length)
}
