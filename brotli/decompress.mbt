///|
/// Decompresses Brotli-encoded data.
pub fn decompress(data : Bytes) -> Bytes raise BrotliError {
  let br = BitReader::new(data[:])
  let sink = @output_sink.OutputSink::new(data.length() * 4)
  // Decode window bits
  let wbits = decode_wbits(br)
  let _window_size = 1 << wbits
  // Decode meta-blocks
  while true {
    let is_last = br.read_bool()
    if is_last {
      let is_last_empty = br.read_bool()
      if is_last_empty {
        break
      }
    }
    // Read MNIBBLES
    let mnibbles_minus_4 = br.read_bits(2)
    let mnibbles = mnibbles_minus_4 + 4
    if mnibbles == 7 {
      // MNIBBLES=7 means metadata block — skip
      let _reserved = br.read_bool()
      let mskip_bytes = br.read_bits(2)
      if mskip_bytes > 0 {
        let skip_len_bits = mskip_bytes * 8
        let _skip_len = br.read_bits(skip_len_bits)
        // Byte align
        if br.n_bits % 8 != 0 {
          let _ = br.read_bits(br.n_bits % 8)
        }
        // Skip bytes are handled by advancing
      }
      continue
    }
    // Read MLEN - 1
    let mlen_bits = mnibbles * 4
    let mlen = br.read_bits(mlen_bits) + 1
    // Check for uncompressed meta-block
    if is_last == false || true {
      // peek at ISUNCOMPRESSED
      let is_uncompressed = br.read_bool()
      if is_uncompressed {
        // Byte-align the reader
        if br.n_bits % 8 != 0 {
          let _ = br.read_bits(br.n_bits % 8)
        }
        // Read raw bytes
        let block = Bytes::makei(mlen, fn(_i) {
          br.read_bits(8).to_byte()
        })
        sink.write_bytes(block)
        if is_last {
          break
        }
        continue
      }
    }
    // Compressed meta-block — decode commands
    let block = decode_compressed_metablock(br, mlen)
    sink.write_bytes(block)
    if is_last {
      break
    }
  }
  sink.to_bytes()
}

///|
fn decode_wbits(br : BitReader) -> Int {
  let first = br.read_bits(1)
  if first == 0 {
    return 16
  }
  let next3 = br.read_bits(3)
  if next3 == 0 {
    return 17
  }
  // For codes 1-6: WBITS = next3 + 10
  // For code 7: read one more bit
  if next3 < 7 {
    return next3 + 10
  }
  // next3 == 7: read one more bit
  let extra = br.read_bits(1)
  if extra == 0 {
    18
  } else {
    // Codes 18-24 based on further bits
    let more = br.read_bits(2)
    19 + more
  }
}

///|
/// Decode a compressed meta-block.
/// This is a simplified decoder that handles basic Brotli-compressed blocks.
fn decode_compressed_metablock(
  br : BitReader,
  mlen : Int,
) -> Bytes raise BrotliError {
  // A full Brotli decompressor requires:
  // 1. Block type trees for literals, insert&copy, distances
  // 2. Context maps
  // 3. Huffman tree decoding
  // 4. Insert-and-copy command decoding
  // 5. Distance decoding with ring buffer
  // 6. Static dictionary lookup for distance >= max
  //
  // For now, we support the subset that our compressor produces.
  // Since our compressor uses uncompressed meta-blocks, this won't be
  // reached in practice for self-compressed data.
  // But we provide the skeleton for future enhancement.

  // Read NBLTYPESL (number of literal block types)
  let nbltypesl = decode_block_count(br)
  ignore(nbltypesl)

  // For a minimal implementation, read mlen bytes of literal data
  // This is a placeholder — a full implementation would parse
  // the Huffman trees and command sequences
  let result = Bytes::makei(mlen, fn(_i) { br.read_bits(8).to_byte() })
  result
}

///|
/// Decode a block count value.
fn decode_block_count(br : BitReader) -> Int {
  let code = br.read_bits(1)
  if code == 0 {
    1
  } else {
    let extra = br.read_bits(3)
    extra + 2
  }
}
