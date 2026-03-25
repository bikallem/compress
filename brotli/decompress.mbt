///|
/// Decompresses Brotli-encoded data.
pub fn decompress(data : Bytes) -> Bytes raise BrotliError {
  guard data.length() > 0 else { raise BrotliError::CorruptData("empty input") }
  let br = BitReader::new(data[:])
  let sink = @blit.Buffer::new(size_hint=data.length() * 4)
  let wbits = decode_wbits(br)
  let window_size = 1 << wbits
  let max_backward = window_size
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
      br.read_bits(1) |> ignore // reserved bit (must be zero per RFC 7932)
      let mskip_bytes = br.read_bits(2)
      if mskip_bytes > 0 {
        let skip_len_bits = mskip_bytes * 8
        br.read_bits(skip_len_bits) |> ignore
        if br.n_bits % 8 != 0 {
          br.read_bits(br.n_bits % 8) |> ignore
        }
      }
      continue
    }
    let mlen_bits = mnibbles * 4
    let mlen = br.read_bits(mlen_bits) + 1
    if is_last {
      decode_compressed_block(br, mlen, sink, max_backward)
      break
    }
    let is_uncompressed = br.read_bool()
    if is_uncompressed {
      if br.n_bits % 8 != 0 {
        br.read_bits(br.n_bits % 8) |> ignore
      }
      sink.ensure_capacity(mlen)
      br.read_bytes_to_sink(sink, mlen)
      continue
    }
    decode_compressed_block(br, mlen, sink, max_backward)
  }
  sink.to_bytes()
}

///|
fn decode_wbits(br : BitReader) -> Int {
  // Bit 0
  let b0 = br.read_bits(1)
  if b0 == 0 {
    return 16
  }
  // Bit 1
  let b1 = br.read_bits(1)
  if b1 == 1 {
    // 4-bit pattern with bit1=1: values 0b0011, 0b0111, 0b1011, 0b1111
    let b23 = br.read_bits(2)
    // Full 4-bit value = 1 + 2 + b23*4 = 3 + b23*4
    // WBITS = (value >> 1) + 17 = ((3 + b23*4) >> 1) + 17
    //       = (1 + b23*2) + 17 = 18 + b23*2
    return 18 + b23 * 2
  }
  // Bit 1 = 0. Bit 2 discriminates 4-bit vs 7-bit.
  let b2 = br.read_bits(1)
  if b2 == 1 {
    // 4-bit pattern with bit1=0, bit2=1: values 0b0101, 0b1101
    let b3 = br.read_bits(1)
    // Full 4-bit value = 1 + 0 + 4 + b3*8 = 5 + b3*8
    // WBITS = (value >> 1) + 17 = (2 + b3*4) + 17 = 19 + b3*4
    return 19 + b3 * 4
  }
  // 7-bit pattern: bits 0,1,2 = 1,0,0. Read remaining 4 bits (bits 3-6).
  let remaining = br.read_bits(4)
  if remaining == 0 {
    return 17
  }
  // remaining is even in {4,6,8,10,12,14} → WBITS = remaining/2 + 8
  remaining / 2 + 8
}

///|
fn decode_compressed_block(
  br : BitReader,
  mlen : Int,
  sink : @blit.Buffer,
  max_backward : Int,
) -> Unit {
  let nbltypesl = decode_block_type_count(br)
  let nbltypesi = decode_block_type_count(br)
  let nbltypesd = decode_block_type_count(br)

  // When NBLTYPES > 1, read block type/count prefix codes and first block count
  let dummy_tree : HuffTree = { table: FixedArray::make(1, 0), max_bits: 0 }

  // Literal block types
  let lit_btype_tree : HuffTree = if nbltypesl > 1 {
    decode_prefix_code(br, nbltypesl + 2)
  } else {
    dummy_tree
  }
  let lit_bcount_tree : HuffTree = if nbltypesl > 1 {
    decode_prefix_code(br, 26)
  } else {
    dummy_tree
  }
  let mut lit_block_remaining = if nbltypesl > 1 {
    decode_block_count(br, lit_bcount_tree)
  } else {
    0
  }
  let mut lit_block_type = 0

  // Insert-and-copy block types
  let iac_btype_tree : HuffTree = if nbltypesi > 1 {
    decode_prefix_code(br, nbltypesi + 2)
  } else {
    dummy_tree
  }
  let iac_bcount_tree : HuffTree = if nbltypesi > 1 {
    decode_prefix_code(br, 26)
  } else {
    dummy_tree
  }
  let mut iac_block_remaining = if nbltypesi > 1 {
    decode_block_count(br, iac_bcount_tree)
  } else {
    0
  }
  let mut iac_block_type = 0

  // Distance block types
  let dist_btype_tree : HuffTree = if nbltypesd > 1 {
    decode_prefix_code(br, nbltypesd + 2)
  } else {
    dummy_tree
  }
  let dist_bcount_tree : HuffTree = if nbltypesd > 1 {
    decode_prefix_code(br, 26)
  } else {
    dummy_tree
  }
  let mut dist_block_remaining = if nbltypesd > 1 {
    decode_block_count(br, dist_bcount_tree)
  } else {
    0
  }
  let mut dist_block_type = 0

  let npostfix = br.read_bits(2)
  let ndirect_raw = br.read_bits(4)
  let ndirect = ndirect_raw << npostfix
  // Read context modes (one per literal block type, 2 bits each)
  let context_modes = FixedArray::make(nbltypesl, 0)
  for i in 0..<nbltypesl {
    context_modes.unsafe_set(i, br.read_bits(2))
  }
  let ntreesl = decode_block_type_count(br)

  // Read context map for literals (RFC 7932: comes after NTREESL, before NTREESD)
  let cmap_size = 64 * nbltypesl
  let cmap_l = if ntreesl > 1 {
    decode_context_map(br, cmap_size, ntreesl)
  } else {
    FixedArray::make(cmap_size, 0)
  }

  let ntreesd = decode_block_type_count(br)

  // Read context map for distances
  let cmap_d_size = 4 * nbltypesd
  let cmap_d = if ntreesd > 1 {
    decode_context_map(br, cmap_d_size, ntreesd)
  } else {
    FixedArray::make(cmap_d_size, 0)
  }

  // Read NTREESL literal prefix codes
  let lit_trees : FixedArray[HuffTree] = FixedArray::make(ntreesl, {
    table: FixedArray::make(1, 0),
    max_bits: 0,
  })
  for i in 0..<ntreesl {
    lit_trees.unsafe_set(i, decode_prefix_code(br, 256))
  }
  let iac_tree = decode_prefix_code(br, 704)
  let dist_alphabet = 16 + ndirect + (48 << npostfix)
  // Read NTREESD distance prefix codes
  let dist_trees : FixedArray[HuffTree] = FixedArray::make(ntreesd, {
    table: FixedArray::make(1, 0),
    max_bits: 0,
  })
  for i in 0..<ntreesd {
    dist_trees.unsafe_set(i, decode_prefix_code(br, dist_alphabet))
  }

  // Distance ring buffer: circular with index, matching C reference layout.
  // C reference: dist_rb[0]=16, dist_rb[1]=15, dist_rb[2]=11, dist_rb[3]=4, idx=0
  // Last distance = dist_rb[(idx-1)&3] = dist_rb[3] = 4
  let dist_rb = FixedArray::make(4, 0)
  dist_rb.unsafe_set(0, 16)
  dist_rb.unsafe_set(1, 15)
  dist_rb.unsafe_set(2, 11)
  dist_rb.unsafe_set(3, 4)
  let mut dist_rb_idx = 0
  let mut distance_context = 0

  // Previous block type per category (for block type ring buffer)
  let mut lit_prev_type = 1
  let mut iac_prev_type = 1
  let mut dist_prev_type = 1

  sink.ensure_capacity(mlen)
  let start_pos = sink.length()
  let mut produced = 0

  while produced < mlen {
    // Check for insert-and-copy block type switch
    if nbltypesi > 1 && iac_block_remaining == 0 {
      let new_type = read_huffman_symbol(br, iac_btype_tree)
      let resolved = resolve_block_type(
        new_type, iac_block_type, iac_prev_type, nbltypesi,
      )
      iac_prev_type = iac_block_type
      iac_block_type = resolved
      iac_block_remaining = decode_block_count(br, iac_bcount_tree)
    }
    if nbltypesi > 1 {
      iac_block_remaining -= 1
    }

    let iac_code = read_huffman_symbol(br, iac_tree)
    let (insert_len, copy_len, needs_dist) = decode_insert_copy(br, iac_code)
    let ilimit = if insert_len > mlen - produced {
      mlen - produced
    } else {
      insert_len
    }
    if ntreesl == 1 && nbltypesl == 1 {
      // Fast path: single literal tree, no block type switching
      let single_tree = lit_trees.unsafe_get(0)
      sink.ensure_capacity(ilimit)
      for _lit_idx in 0..<ilimit {
        let lit = read_huffman_symbol(br, single_tree)
        sink.write_byte_unchecked(lit.to_byte())
        produced += 1
      }
    } else {
      for _lit_idx in 0..<ilimit {
        // Check for literal block type switch
        if nbltypesl > 1 && lit_block_remaining == 0 {
          let new_type = read_huffman_symbol(br, lit_btype_tree)
          let resolved = resolve_block_type(
            new_type, lit_block_type, lit_prev_type, nbltypesl,
          )
          lit_prev_type = lit_block_type
          lit_block_type = resolved
          lit_block_remaining = decode_block_count(br, lit_bcount_tree)
        }
        if nbltypesl > 1 {
          lit_block_remaining -= 1
        }
        // Compute context ID from previous 2 bytes
        let lit_tree = if ntreesl > 1 {
          let pos = start_pos + produced
          let p1 = if pos > 0 { sink.get_byte(pos - 1).to_int() } else { 0 }
          let p2 = if pos > 1 { sink.get_byte(pos - 2).to_int() } else { 0 }
          let context_id = compute_context_id(
            context_modes.unsafe_get(lit_block_type),
            p1,
            p2,
          )
          let tree_idx = cmap_l.unsafe_get(lit_block_type * 64 + context_id)
          lit_trees.unsafe_get(tree_idx)
        } else {
          lit_trees.unsafe_get(0)
        }
        let lit = read_huffman_symbol(br, lit_tree)
        sink.write_byte(lit.to_byte())
        produced += 1
      }
    }
    if produced >= mlen {
      break
    }
    // Distance decode with circular ring buffer (matching C reference)
    let distance = if needs_dist {
      // Check for distance block type switch
      if nbltypesd > 1 && dist_block_remaining == 0 {
        let new_type = read_huffman_symbol(br, dist_btype_tree)
        let resolved = resolve_block_type(
          new_type, dist_block_type, dist_prev_type, nbltypesd,
        )
        dist_prev_type = dist_block_type
        dist_block_type = resolved
        dist_block_remaining = decode_block_count(br, dist_bcount_tree)
      }
      if nbltypesd > 1 {
        dist_block_remaining -= 1
      }
      let dist_tree = if ntreesd > 1 {
        let dist_ctx = if copy_len > 4 { 3 } else { copy_len - 2 }
        let tree_idx = cmap_d.unsafe_get(dist_block_type * 4 + dist_ctx)
        dist_trees.unsafe_get(tree_idx)
      } else {
        dist_trees.unsafe_get(0)
      }
      let dist_code = read_huffman_symbol(br, dist_tree)
      let (d, ctx) = decode_distance_circ(
        br, dist_code, ndirect, dist_rb, dist_rb_idx, npostfix,
      )
      distance_context = ctx
      d
    } else {
      // Implicit distance: reuse last distance
      distance_context = 1
      dist_rb.unsafe_get((dist_rb_idx - 1) & 3)
    }
    let climit = if copy_len > mlen - produced {
      mlen - produced
    } else {
      copy_len
    }
    // Check if this is a dictionary reference
    let max_dist = if start_pos + produced < max_backward {
      start_pos + produced
    } else {
      max_backward
    }
    if distance > max_dist &&
      copy_len >= dict_min_word_length &&
      copy_len <= dict_max_word_length {
      // Static dictionary reference — no ring buffer write, only compensate
      dist_rb_idx += distance_context
      let address = distance - max_dist - 1
      let shift = dict_size_bits_by_length.unsafe_get(copy_len)
      let mask = (1 << shift) - 1
      let word_idx = address & mask
      let transform_idx = address >> shift
      let word_off = dict_word_offset(copy_len, word_idx)
      let tmp = FixedArray::make(copy_len + 128, b'\x00')
      let out_len = transform_dictionary_word(
        tmp, 0, brotli_dictionary_data, word_off, copy_len, transform_idx,
      )
      let write_len = if out_len < climit { out_len } else { climit }
      sink.write_fixed(tmp, 0, write_len)
      produced += write_len
    } else {
      // Backward reference — write distance to ring buffer and advance
      // Only for explicit distances (needs_dist=true)
      if needs_dist {
        dist_rb.unsafe_set(dist_rb_idx & 3, distance)
        dist_rb_idx += 1
      }
      let copy_src = start_pos + produced - distance
      if copy_src >= 0 {
        sink.copy_from_self(copy_src, climit)
        produced += climit
      } else {
        // Edge case: src starts before buffer (pad with zeros)
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
  }
}

///|
/// Compute context ID from previous 2 bytes based on context mode.
/// RFC 7932 Section 7.1.
/// Uses the official context lookup table for all 4 modes.
fn compute_context_id(mode : Int, p1 : Int, p2 : Int) -> Int {
  let lut_offset = mode * 512
  context_lut.unsafe_get(lut_offset + p1) |
  context_lut.unsafe_get(lut_offset + 256 + p2)
}

///|
/// Decode a context map (RFC 7932 Section 7.3).
fn decode_context_map(
  br : BitReader,
  map_size : Int,
  num_trees : Int,
) -> FixedArray[Int] {
  let cmap = FixedArray::make(map_size, 0)
  // Read RLEMAX
  let rlemax_flag = br.read_bits(1)
  let rlemax = if rlemax_flag == 1 { br.read_bits(4) + 1 } else { 0 }
  // Alphabet size for context map = rlemax + num_trees
  let alphabet = rlemax + num_trees
  let cm_tree = decode_prefix_code(br, alphabet)
  let mut i = 0
  while i < map_size {
    let sym = read_huffman_symbol(br, cm_tree)
    if sym == 0 {
      cmap.unsafe_set(i, 0)
      i += 1
    } else if sym <= rlemax {
      // Run-length of zeros: (1 << sym) + extra bits
      let run = (1 << sym) + br.read_bits(sym)
      for _run_idx in 0..<run {
        if i < map_size {
          cmap.unsafe_set(i, 0)
          i += 1
        }
      }
    } else {
      cmap.unsafe_set(i, sym - rlemax)
      i += 1
    }
  }
  // Read IMTF flag
  let imtf = br.read_bits(1)
  if imtf == 1 {
    // Apply inverse move-to-front transform
    let mtf = FixedArray::make(num_trees, 0)
    for j in 0..<num_trees {
      mtf.unsafe_set(j, j)
    }
    for j in 0..<map_size {
      let idx = cmap.unsafe_get(j)
      cmap.unsafe_set(j, mtf.unsafe_get(idx))
      if idx > 0 {
        let val = mtf.unsafe_get(idx)
        // Shift entries down
        for k = idx; k > 0; k = k - 1 {
          mtf.unsafe_set(k, mtf.unsafe_get(k - 1))
        }
        mtf.unsafe_set(0, val)
      }
    }
  }
  cmap
}

///|
/// Decode NBLTYPES using DecodeVarLenUint8 + 1 (RFC 7932 section 9.2).
fn decode_block_type_count(br : BitReader) -> Int {
  let bit0 = br.read_bits(1)
  if bit0 == 0 {
    return 1 // value=0, NBLTYPES=1
  }
  let n = br.read_bits(3)
  if n == 0 {
    return 2 // value=1, NBLTYPES=2
  }
  let extra = br.read_bits(n)
  (1 << n) + extra + 1
}

///|
fn decode_insert_copy(br : BitReader, code : Int) -> (Int, Int, Bool) {
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
    10 => (16, 16, true)
    _ => (16, 16, true) // unreachable: block is code >> 6 with code 0-703
  }
  let insert_code = ib + ir
  let copy_code = cb + cr
  let insert_base = _insert_baselines.unsafe_get(insert_code)
  let insert_extra = _insert_extra_bits.unsafe_get(insert_code)
  let insert_len = insert_base +
    (if insert_extra > 0 { br.read_bits(insert_extra) } else { 0 })
  let copy_base = _copy_baselines.unsafe_get(copy_code)
  let copy_extra = _copy_extra_bits.unsafe_get(copy_code)
  let copy_len = copy_base +
    (if copy_extra > 0 { br.read_bits(copy_extra) } else { 0 })
  (insert_len, copy_len, needs_dist)
}

///|
/// Decode distance and set distance_context, matching C reference TakeDistanceFromRingBuffer.
/// Uses circular ring buffer with dist_rb_idx.
fn decode_distance_circ(
  br : BitReader,
  code : Int,
  ndirect : Int,
  dist_rb : FixedArray[Int],
  dist_rb_idx : Int,
  npostfix : Int,
) -> (Int, Int) {
  if code <= 3 {
    let offset = code - 3
    let d = dist_rb.unsafe_get((dist_rb_idx - offset) & 3)
    // Code 0 (last distance) needs compensation for dictionary roll
    let ctx = if code == 0 { 1 } else { 0 }
    (d, ctx)
  } else if code < 16 {
    // Codes 4-15: ring buffer entry + delta (RFC 7932 Table 9)
    let (index_delta, base) = if code < 10 {
      (3, code - 4)
    } else {
      (2, code - 10)
    }
    // Packed deltas from C reference: nibbles of 0x605142 encode {-1,+1,-2,+2,-3,+3}
    let delta = ((0x605142 >> (4 * base)) & 0xF) - 3
    let d = dist_rb.unsafe_get((dist_rb_idx + index_delta) & 3) + delta
    let d = if d < 1 { 1 } else { d }
    (d, 0)
  } else if code < 16 + ndirect {
    (code - 16 + 1, 0)
  } else {
    let dcode = code - 16 - ndirect
    if npostfix == 0 {
      let hcode = dcode & 1
      let ndistbits = 1 + (dcode >> 1)
      let extra = br.read_bits(ndistbits)
      let offset = ((2 + hcode) << ndistbits) - 4
      (offset + extra + ndirect + 1, 0)
    } else {
      let postfix_mask = (1 << npostfix) - 1
      let postfix = dcode & postfix_mask
      let dcode2 = dcode >> npostfix
      let hcode = dcode2 & 1
      let ndistbits = 1 + (dcode2 >> 1)
      let extra = br.read_bits(ndistbits)
      let offset = ((2 + hcode) << ndistbits) - 4
      (((offset + extra) << npostfix) + postfix + ndirect + 1, 0)
    }
  }
}

///|
/// Decode a block count value (RFC 7932 section 6).
fn decode_block_count(br : BitReader, tree : HuffTree) -> Int {
  let code = read_huffman_symbol(br, tree)
  // RFC 7932 Table 2: Block count codes
  let (base, extra) = match code {
    0 => (1, 2)
    1 => (5, 2)
    2 => (9, 2)
    3 => (13, 2)
    4 => (17, 3)
    5 => (25, 3)
    6 => (33, 3)
    7 => (41, 3)
    8 => (49, 4)
    9 => (65, 4)
    10 => (81, 4)
    11 => (97, 4)
    12 => (113, 5)
    13 => (145, 5)
    14 => (177, 5)
    15 => (209, 5)
    16 => (241, 6)
    17 => (305, 6)
    18 => (369, 7)
    19 => (497, 8)
    20 => (753, 9)
    21 => (1265, 10)
    22 => (2289, 11)
    23 => (4337, 12)
    24 => (8433, 13)
    25 => (16625, 24)
    _ => (16625, 24) // unreachable: block count codes are 0-25
  }
  base + br.read_bits(extra)
}

///|
/// Resolve a block type symbol to an actual type index.
/// RFC 7932 section 6: symbol 0 = previous type, symbol 1 = current+1 mod n,
/// symbol >= 2 = symbol - 2.
fn resolve_block_type(
  sym : Int,
  current : Int,
  prev : Int,
  num_types : Int,
) -> Int {
  if sym == 0 {
    prev
  } else if sym == 1 {
    (current + 1) % num_types
  } else {
    sym - 2
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
    syms.unsafe_set(i, br.read_bits(sb))
  }
  match nsym {
    1 => {
      // Single symbol: 0 bits consumed per read (symbol is implicit).
      let table = FixedArray::make(1, 0)
      table.unsafe_set(0, (syms.unsafe_get(0) << 8) | 0)
      { table, max_bits: 0 }
    }
    2 => {
      let table = FixedArray::make(2, 0)
      table.unsafe_set(0, (syms.unsafe_get(0) << 8) | 1)
      table.unsafe_set(1, (syms.unsafe_get(1) << 8) | 1)
      { table, max_bits: 1 }
    }
    3 => {
      let table = FixedArray::make(4, 0)
      table.unsafe_set(0, (syms.unsafe_get(0) << 8) | 1)
      table.unsafe_set(1, (syms.unsafe_get(1) << 8) | 2)
      table.unsafe_set(2, (syms.unsafe_get(0) << 8) | 1)
      table.unsafe_set(3, (syms.unsafe_get(2) << 8) | 2)
      { table, max_bits: 2 }
    }
    _ => {
      // Sort 4 symbols (needed for correct table layout)
      for i in 0..<3 {
        for k in (i + 1)..<4 {
          if syms.unsafe_get(k) < syms.unsafe_get(i) {
            let t = syms.unsafe_get(k)
            syms.unsafe_set(k, syms.unsafe_get(i))
            syms.unsafe_set(i, t)
          }
        }
      }
      let tree_select = br.read_bits(1)
      if tree_select == 0 {
        let table = FixedArray::make(4, 0)
        // Match Go decoder layout: table[0]=s0, table[1]=s2, table[2]=s1, table[3]=s3
        table.unsafe_set(0, (syms.unsafe_get(0) << 8) | 2)
        table.unsafe_set(1, (syms.unsafe_get(2) << 8) | 2)
        table.unsafe_set(2, (syms.unsafe_get(1) << 8) | 2)
        table.unsafe_set(3, (syms.unsafe_get(3) << 8) | 2)
        { table, max_bits: 2 }
      } else {
        let table = FixedArray::make(8, 0)
        table.unsafe_set(0, (syms.unsafe_get(0) << 8) | 1)
        table.unsafe_set(2, (syms.unsafe_get(0) << 8) | 1)
        table.unsafe_set(4, (syms.unsafe_get(0) << 8) | 1)
        table.unsafe_set(6, (syms.unsafe_get(0) << 8) | 1)
        table.unsafe_set(1, (syms.unsafe_get(1) << 8) | 2)
        table.unsafe_set(5, (syms.unsafe_get(1) << 8) | 2)
        table.unsafe_set(3, (syms.unsafe_get(2) << 8) | 3)
        table.unsafe_set(7, (syms.unsafe_get(3) << 8) | 3)
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
  a.unsafe_set(0, 1)
  a.unsafe_set(1, 2)
  a.unsafe_set(2, 3)
  a.unsafe_set(3, 4)
  a.unsafe_set(4, 0)
  a.unsafe_set(5, 5)
  a.unsafe_set(6, 17)
  a.unsafe_set(7, 6)
  a.unsafe_set(8, 16)
  a.unsafe_set(9, 7)
  a.unsafe_set(10, 8)
  a.unsafe_set(11, 9)
  a.unsafe_set(12, 10)
  a.unsafe_set(13, 11)
  a.unsafe_set(14, 12)
  a.unsafe_set(15, 13)
  a.unsafe_set(16, 14)
  a.unsafe_set(17, 15)
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
  for j in hskip..<18 {
    let sym = cl_order.unsafe_get(j)
    let cl = read_cl_code_length(br)
    cl_lengths.unsafe_set(sym, cl)
    if cl > 0 {
      space -= 32 >> cl
    }
    if space == 0 {
      break
    }
  }
  let cl_tree = build_hufftree(cl_lengths, 18)
  let code_lengths = FixedArray::make(alphabet_size, 0)
  let mut i = 0
  let mut prev_cl = 8
  let mut space = 32768
  // Repeat state for RFC 7932 section 3.5:
  // Consecutive repeat symbols (16 or 17) accumulate their repeat count.
  let mut repeat = 0
  let mut repeat_code_len = 8
  while i < alphabet_size && space > 0 {
    let sym = read_huffman_symbol(br, cl_tree)
    if sym >= 0 && sym <= 15 {
      // Regular code length symbol
      repeat = 0
      code_lengths.unsafe_set(i, sym)
      if sym > 0 {
        prev_cl = sym
        space -= 32768 >> sym
      }
      i += 1
    } else if sym == 16 {
      // Repeat previous code length
      let extra_bits = 2
      let repeat_delta = br.read_bits(extra_bits) + 3
      let new_len = prev_cl
      if repeat_code_len != new_len {
        repeat = 0
        repeat_code_len = new_len
      }
      let old_repeat = repeat
      if repeat > 0 {
        repeat = (repeat - 2) << extra_bits
      }
      repeat += repeat_delta
      let delta = repeat - old_repeat
      for _repeat_idx in 0..<delta {
        if i < alphabet_size {
          code_lengths.unsafe_set(i, repeat_code_len)
          space -= 32768 >> repeat_code_len
          i += 1
        }
      }
    } else if sym == 17 {
      // Repeat zero code length
      let extra_bits = 3
      let repeat_delta = br.read_bits(extra_bits) + 3
      let new_len = 0
      if repeat_code_len != new_len {
        repeat = 0
        repeat_code_len = new_len
      }
      let old_repeat = repeat
      if repeat > 0 {
        repeat = (repeat - 2) << extra_bits
      }
      repeat += repeat_delta
      let delta = repeat - old_repeat
      for _zero_idx in 0..<delta {
        if i < alphabet_size {
          code_lengths.unsafe_set(i, 0)
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
    _ => (0, 2) // unreachable: peek is masked to 4 bits (0-15)
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
    let cl = code_lengths.unsafe_get(i)
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
      table.unsafe_set(i, entry)
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
    let cl = code_lengths.unsafe_get(i)
    if cl > 0 && cl <= max_len {
      bl_count.unsafe_set(cl, bl_count.unsafe_get(cl) + 1)
    }
  }
  let next_code = FixedArray::make(max_len + 1, 0)
  for bits = 1, code = 0; bits <= max_len; {
    let c = (code + bl_count.unsafe_get(bits - 1)) << 1
    next_code.unsafe_set(bits, c)
    continue bits + 1, c
  }
  for sym in 0..<num_symbols {
    let cl = code_lengths.unsafe_get(sym)
    if cl > 0 && cl <= max_len {
      let code = next_code.unsafe_get(cl)
      next_code.unsafe_set(cl, next_code.unsafe_get(cl) + 1)
      let rev = brotli_reverse_dec(code, cl)
      let step = 1 << cl
      let mut idx = rev
      while idx < table_size {
        table.unsafe_set(idx, (sym << 8) | cl)
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
    return tree.table.unsafe_get(0) >> 8
  }
  br.refill()
  let mask = (1 << tree.max_bits) - 1
  let peek = (br.bits & mask.reinterpret_as_uint().to_uint64()).to_int()
  let entry = tree.table.unsafe_get(peek)
  let sym = entry >> 8
  let cl = entry & 0xFF
  br.bits = br.bits >> cl
  br.n_bits -= cl
  sym
}
