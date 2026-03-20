///|
/// Brotli static dictionary metadata and lookup (RFC 7932).

///|
/// Number of index bits for each word length (4-24).
/// size_bits[L] gives the number of words of length L as 2^size_bits[L].
let dict_size_bits_by_length : FixedArray[Int] = [
  0, 0, 0, 0, 10, 10, 11, 11, 10, 10, 10, 10, 10, 9, 9, 8, 7, 7, 8, 7, 7, 6, 6, 5,
  5, 0, 0, 0, 0, 0, 0, 0,
]

///|
/// Byte offset into dictionary data for each word length.
let dict_offsets_by_length : FixedArray[Int] = [
  0, 0, 0, 0, 0, 4096, 9216, 21504, 35840, 44032, 53248, 63488, 74752, 87040, 93696,
  100864, 104704, 106752, 108928, 113536, 115968, 118528, 119872, 121280, 122016,
  122784, 122784, 122784, 122784, 122784, 122784, 122784,
]

///|
/// Minimum and maximum dictionary word lengths.
let dict_min_word_length : Int = 4

///|
let dict_max_word_length : Int = 24

///|
/// Look up a dictionary word by length and index.
/// Returns the offset into brotli_dictionary_data and the word length.
fn dict_word_offset(length : Int, word_idx : Int) -> Int {
  dict_offsets_by_length.unsafe_get(length) + word_idx * length
}
