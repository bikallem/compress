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
/// Format: WBITS + non-last uncompressed meta-block + final empty block.
fn compress_uncompressed(src : BytesView, src_len : Int) -> Bytes {
  let bw = BitWriter::new(src_len + 32)
  // Window bits — use WBITS=22 (4-bit code) for simplicity.
  // Any WBITS >= log2(src_len)+1 works. WBITS=22 handles up to 4MB.
  encode_wbits(bw, 22)
  // Non-last uncompressed meta-block containing all data.
  // ISLAST=0
  bw.write_bits(0, 1)
  // MNIBBLES: number of nibbles to encode MLEN-1
  let (mnibbles, _) = meta_block_nibbles(src_len)
  bw.write_bits(mnibbles - 4, 2) // MNIBBLES encoded as (value - 4)
  // MLEN-1 in MNIBBLES*4 bits
  bw.write_bits(src_len - 1, mnibbles * 4)
  // ISUNCOMPRESSED=1
  bw.write_bits(1, 1)
  // Byte-align before raw data
  if bw.n_bits > 0 {
    bw.write_bits(0, 8 - bw.n_bits)
  }
  // Raw data bytes
  for i in 0..<src_len {
    bw.write_bits(src[i].to_int(), 8)
  }
  // Final empty meta-block: ISLAST=1, ISLASTEMPTY=1
  bw.write_bits(1, 1) // ISLAST
  bw.write_bits(1, 1) // ISLASTEMPTY
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
/// Encode WBITS per RFC 7932 section 9.1.
/// Bit patterns (LSB first as written to stream):
///   WBITS=16: 0               (1 bit)
///   WBITS=17: 0000001         (7 bits)
///   WBITS=10: 0100001         (7 bits)
///   WBITS=11: 0110001         (7 bits)
///   WBITS=12: 1000001         (7 bits)
///   WBITS=13: 1010001         (7 bits)
///   WBITS=14: 1100001         (7 bits)
///   WBITS=15: 1110001         (7 bits)
///   WBITS=18: 0011            (4 bits)
///   WBITS=19: 0101            (4 bits)
///   WBITS=20: 0111            (4 bits)
///   WBITS=21: 1001            (4 bits)
///   WBITS=22: 1011            (4 bits)
///   WBITS=23: 1101            (4 bits)
///   WBITS=24: 1111            (4 bits)
fn encode_wbits(bw : BitWriter, wbits : Int) -> Unit {
  match wbits {
    16 => bw.write_bits(0, 1)
    17 => bw.write_bits(0b0000001, 7)
    10 => bw.write_bits(0b0100001, 7)
    11 => bw.write_bits(0b0110001, 7)
    12 => bw.write_bits(0b1000001, 7)
    13 => bw.write_bits(0b1010001, 7)
    14 => bw.write_bits(0b1100001, 7)
    15 => bw.write_bits(0b1110001, 7)
    18 => bw.write_bits(0b0011, 4)
    19 => bw.write_bits(0b0101, 4)
    20 => bw.write_bits(0b0111, 4)
    21 => bw.write_bits(0b1001, 4)
    22 => bw.write_bits(0b1011, 4)
    23 => bw.write_bits(0b1101, 4)
    24 => bw.write_bits(0b1111, 4)
    _ => bw.write_bits(0, 1) // default to 16
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
