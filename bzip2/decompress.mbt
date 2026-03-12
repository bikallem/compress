///|
/// Decompresses bzip2-encoded data.
pub fn decompress(data : Bytes) -> Bytes raise Bzip2Error {
  let inf = Inflater::new()
  inf.src(data)
  let out = @buffer.new(size_hint=data.length() * 4)
  loop inf.decode() {
    Await => raise Bzip2Error::UnexpectedEOF
    Data(chunk) => {
      out.write_bytes(chunk)
      continue inf.decode()
    }
    End => break
    Error(e) => raise e
  }
  out.to_bytes()
}

///|
/// Performs inverse Burrows-Wheeler Transform using LF mapping.
fn inverse_bwt(data : FixedArray[Int], length : Int, orig_ptr : Int) -> Bytes {
  // Count occurrences of each byte value
  let counts = FixedArray::make(256, 0)
  for i in 0..<length {
    counts[data[i]] += 1
  }
  // Compute cumulative counts (starting positions in F column)
  let cum = FixedArray::make(257, 0)
  let mut total = 0
  for i in 0..<256 {
    cum[i] = total
    total += counts[i]
  }
  cum[256] = total
  // Build LF mapping: for each position i in L, LF[i] = corresponding position in F
  let lf = FixedArray::make(length, 0)
  let occ = FixedArray::make(256, 0)
  for i in 0..<length {
    let c = data[i]
    lf[i] = cum[c] + occ[c]
    occ[c] += 1
  }
  // Reconstruct original string by following LF chain.
  // In bzip2, orig_ptr is the row in the sorted rotation matrix where the
  // original string appears. We output characters by following LF mapping:
  // the i-th character of the original is L[LF^i(orig_ptr)].
  // But since LF maps L position → F position, and F[i] = L[LF^{-1}(i)],
  // we need to follow the chain carefully.
  //
  // Standard approach: output[i] = L[pos], pos = LF[pos]
  // But we need to find the right starting position.
  // orig_ptr is the index in the sorted rotations where the original starts.
  // The first character of the original = F[orig_ptr].
  // F[orig_ptr] = data[T[orig_ptr]] where T is the inverse of LF.
  //
  // Simpler: use the T vector (inverse BWT transform vector).
  // T[i] = LF^{-1}(i): the position in L that maps to sorted position i.
  let t_vec = FixedArray::make(length, 0)
  let pos2 = FixedArray::make(256, 0)
  for i in 0..<256 {
    pos2[i] = cum[i]
  }
  for i in 0..<length {
    let c = data[i]
    t_vec[pos2[c]] = i
    pos2[c] += 1
  }
  // Now t_vec[sorted_pos] = L_pos: F[sorted_pos] corresponds to L[t_vec[sorted_pos]]
  // Follow chain: start at orig_ptr, output L[t_vec[pos]], then pos = lf[t_vec[pos]]...
  // Actually, simpler: just compute the output array directly.
  // decoded[0] = F[orig_ptr], decoded[1] = F[lf[t_vec[orig_ptr]]], ...
  // No, let me use the well-known algorithm from the bzip2 source:
  //
  // Merge data and LF into a single array: tt[i] = (lf[i] << 8) | data[i]
  // Then follow: pos = orig_ptr; for each output char: c = tt[pos] & 0xFF; pos = tt[pos] >> 8
  let tt_merged = FixedArray::make(length, 0)
  for i in 0..<length {
    tt_merged[i] = (lf[i] << 8) | data[i]
  }
  // Output in reverse order since LF goes backwards
  let output = FixedArray::make(length, b'\x00')
  let mut pos = orig_ptr
  for i = length - 1; i >= 0; i = i - 1 {
    let entry = tt_merged[pos]
    output[i] = (entry & 0xFF).to_byte()
    pos = entry >> 8
  }
  let result = @buffer.new(size_hint=length)
  for i in 0..<length {
    result.write_byte(output[i])
  }
  result.to_bytes()
}

///|
/// Undoes bzip2 RLE1 encoding.
/// In RLE1, a run of 4+ identical bytes is stored as:
/// 4 copies of byte + count (where count = number of additional copies beyond 4)
fn undo_rle1(data : Bytes) -> Bytes raise Bzip2Error {
  let out = @buffer.new(size_hint=data.length())
  let mut i = 0
  while i < data.length() {
    let b = data[i]
    out.write_byte(b)
    i += 1
    // Check for run of 4 identical bytes
    if i < data.length() && data[i] == b {
      out.write_byte(b)
      i += 1
      if i < data.length() && data[i] == b {
        out.write_byte(b)
        i += 1
        if i < data.length() && data[i] == b {
          out.write_byte(b)
          i += 1
          // Next byte is repeat count
          if i >= data.length() {
            raise Bzip2Error::CorruptData("unexpected end of RLE1 data")
          }
          let count = data[i].to_int()
          i += 1
          for _ in 0..<count {
            out.write_byte(b)
          }
        }
      }
    }
  }
  out.to_bytes()
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
    t[i] = crc
  }
  t
}

///|
fn bzip2_crc32(data : Bytes) -> UInt {
  let mut crc = 0xFFFFFFFF_U
  for i in 0..<data.length() {
    let idx = ((crc >> 24) ^ data[i].to_uint()) & 0xFFU
    crc = (crc << 8) ^ bzip2_crc_table[idx.reinterpret_as_int()]
  }
  crc ^ 0xFFFFFFFF_U
}
