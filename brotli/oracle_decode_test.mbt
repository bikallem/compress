///|
fn from_hex_nibble(ch : Byte) -> Int {
  if ch >= b'0' && ch <= b'9' {
    ch.to_int() - b'0'.to_int()
  } else if ch >= b'a' && ch <= b'f' {
    ch.to_int() - b'a'.to_int() + 10
  } else if ch >= b'A' && ch <= b'F' {
    ch.to_int() - b'A'.to_int() + 10
  } else {
    0
  }
}

///|
fn hex_bytes(hex : Bytes) -> Bytes {
  let len = hex.length()
  if len % 2 != 0 {
    Bytes::default()
  } else {
    Bytes::makei(len / 2, fn(i) {
      let hi = from_hex_nibble(hex[2 * i])
      let lo = from_hex_nibble(hex[2 * i + 1])
      ((hi << 4) | lo).to_byte()
    })
  }
}

///|
fn structured_binary_fixture() -> Bytes {
  Bytes::makei(2048, fn(i) { (i % 256).to_byte() })
}

///|
test "oracle decode: empty stream" {
  let compressed = hex_bytes(b"33")
  assert_eq(@brotli.decompress(compressed), b"")
}

///|
test "oracle decode: repetitive text" {
  let original = b"The quick brown fox jumps over the lazy dog. The quick brown fox jumps over the lazy dog. The quick brown fox jumps over the lazy dog. The quick brown fox jumps over the lazy dog. The quick brown fox jumps over the lazy dog. The quick brown fox jumps over the lazy dog. The quick brown fox jumps over the lazy dog. The quick brown fox jumps over the lazy dog. The quick brown fox jumps over the lazy dog. The quick brown fox jumps over the lazy dog. The quick brown fox jumps over the lazy dog. The quick brown fox jumps over the lazy dog. The quick brown fox jumps over the lazy dog. The quick brown fox jumps over the lazy dog. The quick brown fox jumps over the lazy dog. The quick brown fox jumps over the lazy dog. The quick brown fox jumps over the lazy dog. The quick brown fox jumps over the lazy dog. The quick brown fox jumps over the lazy dog. The quick brown fox jumps over the lazy dog."
  let compressed = hex_bytes(
    b"138203882c0e78d3d0955d9710bb172ba9cad092cc8cad415ce6f236c8199e9e0a7b830d387048206f24be41a715ce1c1e27aa2938c281b84f8301",
  )
  assert_eq(@brotli.decompress(compressed), original)
}

///|
test "oracle decode: prose fixture" {
  let original = b"Brotli is a general-purpose compression algorithm that combines a modern variant of the LZ77 algorithm, Huffman coding, and 2nd order context modeling. Brotli is a general-purpose compression algorithm that combines a modern variant of the LZ77 algorithm, Huffman coding, and 2nd order context modeling. Brotli is a general-purpose compression algorithm that combines a modern variant of the LZ77 algorithm, Huffman coding, and 2nd order context modeling. Brotli is a general-purpose compression algorithm that combines a modern variant of the LZ77 algorithm, Huffman coding, and 2nd order context modeling. Brotli is a general-purpose compression algorithm that combines a modern variant of the LZ77 algorithm, Huffman coding, and 2nd order context modeling. Brotli is a general-purpose compression algorithm that combines a modern variant of the LZ77 algorithm, Huffman coding, and 2nd order context modeling. "
  let compressed = hex_bytes(
    b"138f03e08dd446f5ce92ecd46da92e941b0cd1643024db512e07fdc16bdce8e48c0fc2df770a2c4fb03327e6816eace51d0c3211dde5fadb0a8da95351c46cb37c0555e5da01762b61c6a7f5cf298efa450e1b862f78826d229341f682d02f4b6d25c000",
  )
  assert_eq(@brotli.decompress(compressed), original)
}

///|
test "oracle decode: structured binary" {
  let original = structured_binary_fixture()
  let compressed = hex_bytes(
    b"13ff07e82f0eec58195843aa078e1a366eed400c6cdbde64b50ece0bb9ef1407e7959c471c840ac70879af2c431c4da42026d8c4b17b7f47570011269471219536d6f910532eb5f531d73ef77d00846004c57082a46886e57841946445d574c3b46cc7f5fc208ce224cdf2a2aceaa6edfa619ce665ddf6e3bceee7fd7e7f00c1088ae10449d10ccbf18228c98aaae98669d98eebf94118c5499ae54559d54ddbf5c338cdcbbaedc779ddcffbfd00224c28e3422a6dacf34118c5499ae54559d54ddbf5c338cdcbbaedc779ddcffbfd2016358fac9ebd8f02",
  )
  assert_eq(@brotli.decompress(compressed), original)
}

///|
test "oracle decode: static dictionary candidate" {
  let compressed = hex_bytes(b"130a00f825000298b0e501")
  assert_eq(@brotli.decompress(compressed), b"compression")
}

///|
test "oracle decode: chunked inflater input" {
  let compressed = hex_bytes(
    b"138f03e08dd446f5ce92ecd46da92e941b0cd1643024db512e07fdc16bdce8e48c0fc2df770a2c4fb03327e6816eace51d0c3211dde5fadb0a8da95351c46cb37c0555e5da01762b61c6a7f5cf298efa450e1b862f78826d229341f682d02f4b6d25c000",
  )
  let expected = b"Brotli is a general-purpose compression algorithm that combines a modern variant of the LZ77 algorithm, Huffman coding, and 2nd order context modeling. Brotli is a general-purpose compression algorithm that combines a modern variant of the LZ77 algorithm, Huffman coding, and 2nd order context modeling. Brotli is a general-purpose compression algorithm that combines a modern variant of the LZ77 algorithm, Huffman coding, and 2nd order context modeling. Brotli is a general-purpose compression algorithm that combines a modern variant of the LZ77 algorithm, Huffman coding, and 2nd order context modeling. Brotli is a general-purpose compression algorithm that combines a modern variant of the LZ77 algorithm, Huffman coding, and 2nd order context modeling. Brotli is a general-purpose compression algorithm that combines a modern variant of the LZ77 algorithm, Huffman coding, and 2nd order context modeling. "
  let inflater = @brotli.Inflater::new()
  let out = @buffer.new()
  let mut pos = 0
  loop inflater.decode() {
    Await =>
      if pos >= compressed.length() {
        fail("unexpected Await after all compressed bytes consumed")
      } else {
        let end = if pos + 3 > compressed.length() {
          compressed.length()
        } else {
          pos + 3
        }
        let chunk = Bytes::makei(end - pos, fn(i) { compressed[pos + i] })
        inflater.src(chunk[:])
        pos = end
        continue inflater.decode()
      }
    Data(chunk) => {
      out.write_bytes(chunk)
      continue inflater.decode()
    }
    End => assert_eq(out.to_bytes(), expected)
    Error(e) => raise e
  }
}
