///|
/// Fixed literal/length Huffman decoder (RFC 1951 section 3.2.6).
let fixed_lit_decoder : HuffmanDecoder = {
  let lengths = FixedArray::make(288, 0)
  for i in 0..<=143 {
    lengths.unsafe_set(i, 8)
  }
  for i in 144..<=255 {
    lengths.unsafe_set(i, 9)
  }
  for i in 256..<=279 {
    lengths.unsafe_set(i, 7)
  }
  for i in 280..<=287 {
    lengths.unsafe_set(i, 8)
  }
  HuffmanDecoder::build(lengths) catch {
    _ => abort("failed to build fixed literal Huffman table")
  }
}

///|
/// Fixed distance Huffman decoder (RFC 1951 section 3.2.6).
let fixed_dist_decoder : HuffmanDecoder = {
  let lengths = FixedArray::make(32, 0)
  for i in 0..<30 {
    lengths.unsafe_set(i, 5)
  }
  HuffmanDecoder::build(lengths) catch {
    _ => abort("failed to build fixed distance Huffman table")
  }
}
