///|
/// Fixed literal/length Huffman decoder (RFC 1951 section 3.2.6).
let fixed_lit_decoder : HuffmanDecoder = {
  let lengths = FixedArray::make(288, 0)
  // 0-143: 8 bits
  for i in 0..<=143 {
    lengths[i] = 8
  }
  // 144-255: 9 bits
  for i in 144..<=255 {
    lengths[i] = 9
  }
  // 256-279: 7 bits
  for i in 256..<=279 {
    lengths[i] = 7
  }
  // 280-287: 8 bits
  for i in 280..<=287 {
    lengths[i] = 8
  }
  // This should never fail for the fixed table
  HuffmanDecoder::build(lengths) catch {
    _ => abort("failed to build fixed literal Huffman table")
  }
}

///|
/// Fixed distance Huffman decoder (RFC 1951 section 3.2.6).
let fixed_dist_decoder : HuffmanDecoder = {
  let lengths = FixedArray::make(32, 0)
  // All 32 distance codes are 5 bits
  for i in 0..<30 {
    lengths[i] = 5
  }
  HuffmanDecoder::build(lengths) catch {
    _ => abort("failed to build fixed distance Huffman table")
  }
}
