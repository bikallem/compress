///|
/// Decompresses bzip2-encoded data.
pub fn decompress(data : Bytes) -> Bytes raise Bzip2Error {
  let inf = Inflater::new()
  inf.src(data[:])
  inf.finish()
  let capacity = (data.length() * 4).max(32768)
  let sink = @blit.Buffer::new(size_hint=capacity)
  loop inf.decode() {
    Await => raise Bzip2Error::UnexpectedEOF
    Data(chunk) => {
      sink.write_bytesview(chunk)
      continue inf.decode()
    }
    End => break
    Error(e) => raise e
  }
  sink.to_bytes()
}

///|
/// Performs inverse Burrows-Wheeler Transform.
/// Builds LF mapping in-place: tt[i] = (lf[i] << 8) | byte_value,
/// then walks the merged array to produce the output.
fn inverse_bwt(data : FixedArray[Int], length : Int, orig_ptr : Int) -> Bytes {
  // Count occurrences of each byte value
  let counts = FixedArray::make(256, 0)
  for i in 0..<length {
    counts.unsafe_set(
      data.unsafe_get(i),
      counts.unsafe_get(data.unsafe_get(i)) + 1,
    )
  }
  // Compute cumulative counts (starting positions in F column)
  let cum = FixedArray::make(256, 0)
  for i = 0, total = 0; i < 256; i = i + 1 {
    cum.unsafe_set(i, total)
    continue i + 1, total + counts.unsafe_get(i)
  }
  // Build merged TT in-place: tt[i] = (lf_pos << 8) | byte_value
  // This avoids allocating separate lf and tt_merged arrays.
  let occ = FixedArray::make(256, 0)
  for i in 0..<length {
    let c = data.unsafe_get(i)
    let lf_pos = cum.unsafe_get(c) + occ.unsafe_get(c)
    occ.unsafe_set(c, occ.unsafe_get(c) + 1)
    data.unsafe_set(i, (lf_pos << 8) | c)
  }
  // Walk the merged TT to produce output
  let output = @blit.make_uninit(length)
  let mut pos = orig_ptr
  for i = length - 1; i >= 0; i = i - 1 {
    let entry = data.unsafe_get(pos)
    output.unsafe_set(i, (entry & 0xFF).to_byte())
    pos = entry >> 8
  }
  output.unsafe_reinterpret_as_bytes()
}

///|
/// Undoes bzip2 RLE1 encoding.
/// In RLE1, a run of 4+ identical bytes is stored as:
/// 4 copies of byte + count (where count = number of additional copies beyond 4)
fn undo_rle1(data : Bytes, max_block_bytes : Int) -> Bytes raise Bzip2Error {
  let len = data.length()
  // The output is the original block data before RLE1 encoding, which is
  // bounded by max_block_bytes. Add 256 for one trailing run expansion.
  let max_out = max_block_bytes + 256
  let out = FixedArray::make(max_out, b'\x00')
  let mut pos = 0
  let mut i = 0
  while i < len {
    let b = data.unsafe_get(i)
    out.unsafe_set(pos, b)
    pos += 1
    i += 1
    // Check for run of 4 identical bytes
    if i < len && data.unsafe_get(i) == b {
      out.unsafe_set(pos, b)
      pos += 1
      i += 1
      if i < len && data.unsafe_get(i) == b {
        out.unsafe_set(pos, b)
        pos += 1
        i += 1
        if i < len && data.unsafe_get(i) == b {
          out.unsafe_set(pos, b)
          pos += 1
          i += 1
          // Next byte is repeat count
          if i >= len {
            raise Bzip2Error::CorruptData("unexpected end of RLE1 data")
          }
          let count = data.unsafe_get(i).to_int()
          i += 1
          for _ in 0..<count {
            out.unsafe_set(pos, b)
            pos += 1
          }
        }
      }
    }
  }
  let result = @blit.make_uninit(pos)
  @blit.blit_fixed_array(result, 0, out, 0, pos)
  result.unsafe_reinterpret_as_bytes()
}

///|
/// bzip2 CRC-32 (non-reflected polynomial 0x04C11DB7).
let bzip2_crc_table : FixedArray[UInt] = {
  let t = FixedArray::make(256, 0U)
  for i in 0..<256 {
    let mut crc = i.reinterpret_as_uint() << 24
    for _ in 0..<8 {
      if (crc & 0x80000000U) != 0U {
        crc = (crc << 1) ^ 0x04C11DB7U
      } else {
        crc = crc << 1
      }
    }
    t.unsafe_set(i, crc)
  }
  t
}

///|
fn bzip2_crc32(data : Bytes) -> UInt {
  let mut crc = 0xFFFFFFFF_U
  for b in data {
    let idx = ((crc >> 24) ^ b.to_uint()) & 0xFFU
    crc = (crc << 8) ^ bzip2_crc_table.unsafe_get(idx.reinterpret_as_int())
  }
  crc ^ 0xFFFFFFFF_U
}
