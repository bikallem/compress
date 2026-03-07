///|
test "inflate empty" {
  // Raw deflate of empty data: single empty stored block
  let compressed : Bytes = b"\x03\x00"
  let result = @flate.decompress(compressed)
  inspect(result.length(), content="0")
}

///|
test "inflate stored block" {
  // Raw deflate stored block of "Hello"
  let compressed : Bytes = b"\x01\x05\x00\xfa\xff\x48\x65\x6c\x6c\x6f"
  let result = @flate.decompress(compressed)
  let expected : Bytes = b"Hello"
  inspect(result == expected, content="true")
}

///|
test "inflate fixed huffman" {
  // Raw deflate fixed Huffman of "Hello"
  let compressed : Bytes = b"\xf3\x48\xcd\xc9\xc9\x07\x00"
  let result = @flate.decompress(compressed)
  let expected : Bytes = b"Hello"
  inspect(result == expected, content="true")
}

///|
test "inflate dynamic huffman" {
  // Raw deflate of "Hello, World!" with default level
  let compressed : Bytes = b"\xf3\x48\xcd\xc9\xc9\xd7\x51\x08\xcf\x2f\xca\x49\x51\x04\x00"
  let result = @flate.decompress(compressed)
  let expected : Bytes = b"Hello, World!"
  inspect(result == expected, content="true")
}

///|
test "inflate corrupt input" {
  let result = try? @flate.decompress(b"\xFF\xFF")
  inspect(result is Err(_), content="true")
}

///|
test "inflate truncated input" {
  let result = try? @flate.decompress(b"\xf3\x48")
  inspect(result is Err(_), content="true")
}
