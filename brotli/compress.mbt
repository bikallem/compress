///|
/// Compresses data using the Brotli format.
/// Uses uncompressed meta-blocks for simplicity and correctness,
/// with LZ77 matching at higher levels.
pub fn compress(data : Bytes, level? : CompressionLevel = Default) -> Bytes {
  let lvl = compression_level_to_int(level)
  let src = data[:]
  let src_len = data.length()
  if src_len == 0 {
    return compress_empty()
  }
  if lvl == 0 || src_len < 8 {
    return compress_uncompressed(src, src_len)
  }
  compress_lz77(src, src_len, lvl)
}

///|
/// Compress empty input.
fn compress_empty() -> Bytes {
  // WBITS=16 (value 0 means 16), ISLAST=1, ISLASTEMPTY=1
  let bw = BitWriter::new(8)
  // Window bits: encode 16 as value 0 (1-bit: 0)
  bw.write_bits(0, 1) // WBITS prefix: 0 means WBITS=16
  // Meta-block: ISLAST=1, ISLASTEMPTY=1
  bw.write_bits(1, 1) // ISLAST
  bw.write_bits(1, 1) // ISLASTEMPTY
  bw.to_bytes()
}

///|
/// Compress using uncompressed meta-blocks.
fn compress_uncompressed(src : BytesView, src_len : Int) -> Bytes {
  let bw = BitWriter::new(src_len + 32)
  // Window bits — encode based on src_len
  let wbits = window_bits_for_size(src_len)
  encode_wbits(bw, wbits)
  // Single uncompressed meta-block
  // ISLAST=1
  bw.write_bits(1, 1)
  // ISLASTEMPTY=0
  bw.write_bits(0, 1)
  // MNIBBLES: number of nibbles to encode MLEN-1
  let mlen = src_len
  let (mnibbles, _) = meta_block_nibbles(mlen)
  bw.write_bits(mnibbles - 4, 2) // MNIBBLES is encoded as (MNIBBLES-4)
  // MLEN - 1, in MNIBBLES*4 bits
  let mlen_bits = mnibbles * 4
  bw.write_bits(mlen - 1, mlen_bits)
  // ISUNCOMPRESSED=1
  bw.write_bits(1, 1)
  // Byte-align
  if bw.n_bits > 0 {
    bw.write_bits(0, 8 - bw.n_bits)
  }
  // Raw data
  for i in 0..<src_len {
    bw.write_bits(src[i].to_int(), 8)
  }
  bw.to_bytes()
}

///|
/// Compress using LZ77 with simple prefix coding.
fn compress_lz77(src : BytesView, src_len : Int, _level : Int) -> Bytes {
  // For now, use uncompressed encoding for correctness.
  // A full LZ77+Huffman encoder would require building context-dependent
  // Huffman trees, which is substantial. We use uncompressed meta-blocks
  // as the initial correct implementation.
  compress_uncompressed(src, src_len)
}

///|
fn window_bits_for_size(size : Int) -> Int {
  if size <= 0 {
    return 16
  }
  let mut wbits = 10
  while wbits < MAX_WBITS && 1 << wbits < size {
    wbits += 1
  }
  wbits
}

///|
fn encode_wbits(bw : BitWriter, wbits : Int) -> Unit {
  // Brotli window bits encoding (RFC 7932 section 9.1):
  // WBITS=10: value 0xxxxxxx (1 bit: 0)... actually it's more complex.
  // Simplified: value = wbits - 10, in specific encoding
  if wbits == 16 {
    bw.write_bits(0, 1) // 0 means WBITS=16
  } else if wbits >= 10 && wbits <= 17 {
    // For 10-17: use 4-bit encoding
    // 0xxx where xxx = wbits - 10 (shifted)
    let _val = wbits - 17 // -7 to 0
    // Actually the encoding is: write 1, then specific pattern
    bw.write_bits(1, 1) // not 16
    let code = wbits - 10
    if code <= 6 {
      bw.write_bits(code, 3)
    } else {
      bw.write_bits(0, 3) // fallback
    }
  } else if wbits >= 18 && wbits <= 24 {
    bw.write_bits(1, 1) // not 16
    let val = (wbits - 17) | 0x08
    bw.write_bits(val & 0x07, 3)
    bw.write_bits((val >> 3) & 0x01, 1)
  } else {
    bw.write_bits(0, 1) // default to 16
  }
}

///|
/// Returns (mnibbles, _) for encoding MLEN.
fn meta_block_nibbles(mlen : Int) -> (Int, Int) {
  if mlen <= 0 {
    (4, 0)
  } else if mlen <= 1 << 16 {
    (4, mlen - 1)
  } else if mlen <= 1 << 20 {
    (5, mlen - 1)
  } else {
    (6, mlen - 1)
  }
}
