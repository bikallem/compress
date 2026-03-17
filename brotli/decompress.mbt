///|
/// Decompresses Brotli-encoded data.
pub fn decompress(data : Bytes) -> Bytes raise BrotliError {
  guard data.length() > 0 else {
    raise BrotliError::CorruptData("empty input")
  }
  let br = BitReader::new(data[:])
  let sink = @output_sink.OutputSink::new(data.length() * 4)
  let wbits = decode_wbits(br)
  let _window_size = 1 << wbits
  while true {
    let is_last = br.read_bool()
    if is_last {
      let is_last_empty = br.read_bool()
      if is_last_empty {
        break
      }
    }
    let mnibbles_minus_4 = br.read_bits(2)
    let mnibbles = mnibbles_minus_4 + 4
    if mnibbles == 7 {
      let _reserved = br.read_bool()
      let mskip_bytes = br.read_bits(2)
      if mskip_bytes > 0 {
        let skip_len_bits = mskip_bytes * 8
        let _skip_len = br.read_bits(skip_len_bits)
        if br.n_bits % 8 != 0 {
          let _ = br.read_bits(br.n_bits % 8)
        }
      }
      continue
    }
    let mlen_bits = mnibbles * 4
    let mlen = br.read_bits(mlen_bits) + 1
    if is_last {
      decode_compressed_block(br, mlen, sink)
      break
    }
    let is_uncompressed = br.read_bool()
    if is_uncompressed {
      if br.n_bits % 8 != 0 {
        let _ = br.read_bits(br.n_bits % 8)
      }
      for _ in 0..<mlen {
        sink.write_byte(br.read_bits(8).to_byte())
      }
      continue
    }
    decode_compressed_block(br, mlen, sink)
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
  if next3 < 7 {
    return next3 + 10
  }
  let extra = br.read_bits(1)
  if extra == 0 {
    18
  } else {
    let more = br.read_bits(2)
    19 + more
  }
}

///|
fn decode_compressed_block(
  br : BitReader,
  mlen : Int,
  sink : @output_sink.OutputSink,
) -> Unit {
  let _nbltypesl = decode_block_type_count(br)
  let _nbltypesi = decode_block_type_count(br)
  let _nbltypesd = decode_block_type_count(br)
  let npostfix = br.read_bits(2)
  let ndirect_raw = br.read_bits(4)
  let ndirect = ndirect_raw << npostfix
  let _context_mode = br.read_bits(2)
  let _ntreesl = decode_block_type_count(br)
  let _ntreesd = decode_block_type_count(br)

  let lit_tree = decode_prefix_code(br, 256)
  let iac_tree = decode_prefix_code(br, 704)
  let dist_alphabet = 16 + ndirect + (48 << npostfix)
  let dist_tree = decode_prefix_code(br, dist_alphabet)

  let dist_rb = FixedArray::make(4, 1)
  dist_rb[0] = 4
  dist_rb[1] = 11
  dist_rb[2] = 15
  dist_rb[3] = 16

  sink.ensure_capacity(mlen)
  let start_pos = sink.length()
  let mut produced = 0

  while produced < mlen {
    let iac_code = read_huffman_symbol(br, iac_tree)
    let (insert_len, copy_len, needs_dist) = decode_insert_copy(br, iac_code)
    let ilimit = if insert_len > mlen - produced {
      mlen - produced
    } else {
      insert_len
    }
    for _ in 0..<ilimit {
      let lit = read_huffman_symbol(br, lit_tree)
      sink.write_byte(lit.to_byte())
      produced += 1
    }
    if produced >= mlen {
      break
    }
    let distance = if needs_dist {
      let dist_code = read_huffman_symbol(br, dist_tree)
      let d = decode_distance(br, dist_code, ndirect, dist_rb)
      dist_rb[3] = dist_rb[2]
      dist_rb[2] = dist_rb[1]
      dist_rb[1] = dist_rb[0]
      dist_rb[0] = d
      d
    } else {
      dist_rb[0]
    }
    let climit = if copy_len > mlen - produced {
      mlen - produced
    } else {
      copy_len
    }
    let copy_src = start_pos + produced - distance
    for j in 0..<climit {
      let src_pos = copy_src + j
      let b = if src_pos >= 0 && src_pos < sink.length() {
        sink.get_byte(src_pos)
      } else {
        b'\x00'
      }
      sink.write_byte(b)
      produced += 1
    }
  }
}

///|
fn decode_block_type_count(br : BitReader) -> Int {
  let code = br.read_bits(1)
  if code == 0 {
    1
  } else {
    br.read_bits(3) + 2
  }
}

///|
fn decode_insert_copy(
  br : BitReader,
  code : Int,
) -> (Int, Int, Bool) {
  let block = code >> 6
  let sub = code & 63
  let ir = (sub >> 3) & 7
  let cr = sub & 7
  let (ib, cb, needs_dist) = match block {
    0 => (0, 0, false)
    1 => (0, 8, false)
    2 => (0, 0, true)
    3 => (0, 8, true)
    4 => (8, 0, true)
    5 => (8, 8, true)
    6 => (0, 16, true)
    7 => (16, 0, true)
    8 => (8, 16, true)
    9 => (16, 8, true)
    _ => (16, 16, true)
  }
  let insert_code = ib + ir
  let copy_code = cb + cr
  let insert_base = _insert_baselines[insert_code]
  let insert_extra = _insert_extra_bits[insert_code]
  let insert_len = insert_base + (if insert_extra > 0 {
    br.read_bits(insert_extra)
  } else {
    0
  })
  let copy_base = _copy_baselines[copy_code]
  let copy_extra = _copy_extra_bits[copy_code]
  let copy_len = copy_base + (if copy_extra > 0 {
    br.read_bits(copy_extra)
  } else {
    0
  })
  (insert_len, copy_len, needs_dist)
}

///|
fn decode_distance(
  br : BitReader,
  code : Int,
  ndirect : Int,
  dist_rb : FixedArray[Int],
) -> Int {
  if code < 4 {
    return dist_rb[code]
  }
  if code < 16 {
    let (rb_idx, delta) = match code {
      4 => (0, 1)
      5 => (0, -1)
      6 => (0, 2)
      7 => (0, -2)
      8 => (0, 3)
      9 => (0, -3)
      10 => (1, 1)
      11 => (1, -1)
      12 => (1, 2)
      13 => (1, -2)
      14 => (2, 1)
      _ => (2, -1)
    }
    let d = dist_rb[rb_idx] + delta
    if d < 1 { 1 } else { d }
  } else if code < 16 + ndirect {
    code - 16 + 1
  } else {
    let dcode = code - 16 - ndirect
    let hcode = dcode & 1
    let ndistbits = 1 + (dcode >> 1)
    let extra = br.read_bits(ndistbits)
    let offset = ((2 + hcode) << ndistbits) - 4
    offset + extra + ndirect + 1
  }
}

// ─── Huffman decode tree ─────────────────────────────────────────────

///|
priv struct HuffTree {
  table : FixedArray[Int]
  max_bits : Int
}

///|
fn decode_prefix_code(br : BitReader, alphabet_size : Int) -> HuffTree {
  let hskip = br.read_bits(2)
  if hskip == 1 {
    return decode_simple_prefix(br, alphabet_size)
  }
  decode_complex_prefix(br, alphabet_size, hskip)
}

///|
fn decode_simple_prefix(br : BitReader, alphabet_size : Int) -> HuffTree {
  let nsym = br.read_bits(2) + 1
  let sb = brotli_sym_bits(alphabet_size)
  let syms = FixedArray::make(nsym, 0)
  for i in 0..<nsym {
    syms[i] = br.read_bits(sb)
  }
  match nsym {
    1 => {
      let table = FixedArray::make(2, 0)
      table[0] = (syms[0] << 8) | 1
      table[1] = (syms[0] << 8) | 1
      { table, max_bits: 1 }
    }
    2 => {
      let table = FixedArray::make(2, 0)
      table[0] = (syms[0] << 8) | 1
      table[1] = (syms[1] << 8) | 1
      { table, max_bits: 1 }
    }
    3 => {
      let table = FixedArray::make(4, 0)
      table[0] = (syms[0] << 8) | 1
      table[1] = (syms[1] << 8) | 2
      table[2] = (syms[0] << 8) | 1
      table[3] = (syms[2] << 8) | 2
      { table, max_bits: 2 }
    }
    _ => {
      let tree_select = br.read_bits(1)
      if tree_select == 0 {
        let table = FixedArray::make(4, 0)
        table[0] = (syms[0] << 8) | 2
        table[1] = (syms[1] << 8) | 2
        table[2] = (syms[2] << 8) | 2
        table[3] = (syms[3] << 8) | 2
        { table, max_bits: 2 }
      } else {
        let table = FixedArray::make(8, 0)
        table[0] = (syms[0] << 8) | 1
        table[2] = (syms[0] << 8) | 1
        table[4] = (syms[0] << 8) | 1
        table[6] = (syms[0] << 8) | 1
        table[1] = (syms[1] << 8) | 2
        table[5] = (syms[1] << 8) | 2
        table[3] = (syms[2] << 8) | 3
        table[7] = (syms[3] << 8) | 3
        { table, max_bits: 3 }
      }
    }
  }
}

///|
fn brotli_sym_bits(alphabet_size : Int) -> Int {
  if alphabet_size <= 1 {
    return 0
  }
  let mut bits = 0
  let mut v = alphabet_size - 1
  while v > 0 {
    bits += 1
    v = v >> 1
  }
  bits
}

///|
let cl_order : FixedArray[Int] = {
  let a = FixedArray::make(18, 0)
  a[0] = 1; a[1] = 2; a[2] = 3; a[3] = 4; a[4] = 0
  a[5] = 5; a[6] = 17; a[7] = 6; a[8] = 16; a[9] = 7
  a[10] = 8; a[11] = 9; a[12] = 10; a[13] = 11
  a[14] = 12; a[15] = 13; a[16] = 14; a[17] = 15
  a
}

///|
fn decode_complex_prefix(
  br : BitReader,
  alphabet_size : Int,
  hskip : Int,
) -> HuffTree {
  let cl_lengths = FixedArray::make(18, 0)
  let mut space = 32
  let mut num_codes = 0
  for j = hskip; j < 18; j = j + 1 {
    if num_codes >= 2 && space == 0 {
      break
    }
    let sym = cl_order[j]
    let cl = read_cl_code_length(br)
    cl_lengths[sym] = cl
    if cl > 0 {
      space -= 32 >> cl
      num_codes += 1
    }
  }
  let cl_tree = build_hufftree(cl_lengths, 18)
  let code_lengths = FixedArray::make(alphabet_size, 0)
  let mut i = 0
  let mut prev_cl = 8
  while i < alphabet_size {
    let sym = read_huffman_symbol(br, cl_tree)
    if sym >= 0 && sym <= 15 {
      code_lengths[i] = sym
      if sym > 0 {
        prev_cl = sym
      }
      i += 1
    } else if sym == 16 {
      let repeat = br.read_bits(2) + 3
      for _ in 0..<repeat {
        if i < alphabet_size {
          code_lengths[i] = prev_cl
          i += 1
        }
      }
    } else if sym == 17 {
      let repeat = br.read_bits(3) + 3
      for _ in 0..<repeat {
        if i < alphabet_size {
          code_lengths[i] = 0
          i += 1
        }
      }
    }
  }
  build_hufftree(code_lengths, alphabet_size)
}

///|
fn read_cl_code_length(br : BitReader) -> Int {
  br.refill()
  let peek = (br.bits & 0xFUL).to_int()
  let (value, length) = match peek {
    0 | 4 | 8 | 12 => (0, 2)
    1 | 5 | 9 | 13 => (4, 2)
    2 | 6 | 10 | 14 => (3, 2)
    3 | 11 => (2, 3)
    7 => (1, 4)
    15 => (5, 4)
    _ => (0, 2)
  }
  br.bits = br.bits >> length
  br.n_bits -= length
  value
}

///|
fn build_hufftree(
  code_lengths : FixedArray[Int],
  num_symbols : Int,
) -> HuffTree {
  let mut max_len = 0
  let mut nsym = 0
  let mut only_sym = 0
  for i in 0..<num_symbols {
    let cl = code_lengths[i]
    if cl > 0 {
      nsym += 1
      only_sym = i
      if cl > max_len {
        max_len = cl
      }
    }
  }
  if nsym == 0 {
    return { table: FixedArray::make(1, 0), max_bits: 0 }
  }
  if nsym == 1 {
    let cl = max_len
    let table_size = 1 << cl
    let table = FixedArray::make(table_size, 0)
    let entry = (only_sym << 8) | cl
    for i in 0..<table_size {
      table[i] = entry
    }
    return { table, max_bits: cl }
  }
  if max_len > 15 {
    max_len = 15
  }
  let table_size = 1 << max_len
  let table = FixedArray::make(table_size, 0)
  let bl_count = FixedArray::make(max_len + 1, 0)
  for i in 0..<num_symbols {
    let cl = code_lengths[i]
    if cl > 0 && cl <= max_len {
      bl_count[cl] += 1
    }
  }
  let next_code = FixedArray::make(max_len + 1, 0)
  for bits = 1, code = 0; bits <= max_len; {
    let c = (code + bl_count[bits - 1]) << 1
    next_code[bits] = c
    continue bits + 1, c
  }
  for sym in 0..<num_symbols {
    let cl = code_lengths[sym]
    if cl > 0 && cl <= max_len {
      let code = next_code[cl]
      next_code[cl] += 1
      let rev = brotli_reverse_dec(code, cl)
      let step = 1 << cl
      let mut idx = rev
      while idx < table_size {
        table[idx] = (sym << 8) | cl
        idx += step
      }
    }
  }
  { table, max_bits: max_len }
}

///|
fn brotli_reverse_dec(val : Int, n : Int) -> Int {
  let (result, _) = for result = 0, v = val, i = 0; i < n; {
    continue (result << 1) | (v & 1), v >> 1, i + 1
  } nobreak {
    (result, val)
  }
  result
}

///|
fn read_huffman_symbol(br : BitReader, tree : HuffTree) -> Int {
  if tree.max_bits == 0 {
    return tree.table[0] >> 8
  }
  br.refill()
  let mask = (1 << tree.max_bits) - 1
  let peek = (br.bits & mask.reinterpret_as_uint().to_uint64()).to_int()
  let entry = tree.table[peek]
  let sym = entry >> 8
  let cl = entry & 0xFF
  br.bits = br.bits >> cl
  br.n_bits -= cl
  sym
}
