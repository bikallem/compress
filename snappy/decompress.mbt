///|
/// Decompresses Snappy-encoded data.
pub fn decompress(data : Bytes) -> Bytes raise SnappyError {
  let inf = Inflater::new()
  inf.src(data[:])
  let capacity = (data.length() * 2).max(256)
  inf.enable_direct_output(capacity)
  loop inf.decode() {
    Await => raise SnappyError::UnexpectedEOF
    Data(_) => continue inf.decode()
    End => inf.take_output()
    Error(e) => raise e
  }
}

///|
fn snappy_decompress_prefix(
  data : Bytes,
  sink : @blit.Buffer,
) -> Bool raise SnappyError {
  guard data.length() > 0 else { return false }
  let read_len_result = try? read_varint(data[:], 0)
  let (uncompressed_len, data_start) = match read_len_result {
    Ok(v) => v
    Err(e) =>
      match e {
        UnexpectedEOF => return false
        _ => raise e
      }
  }
  if uncompressed_len == 0 {
    guard data_start == data.length() else {
      raise SnappyError::CorruptInput("trailing bytes after end of stream")
    }
    return true
  }
  let dst = FixedArray::make(uncompressed_len, b'\x00')
  let (written, complete) = decode_block_prefix(
    data[:],
    data_start,
    dst,
    uncompressed_len,
  )
  if written > 0 {
    sink.write_fixed(dst, 0, written)
  }
  complete
}

///|
/// Reads a varint from data starting at pos. Returns (value, new_pos).
fn read_varint(data : BytesView, pos_ : Int) -> (Int, Int) raise SnappyError {
  let mut pos = pos_
  let mut result = 0
  let mut shift = 0
  while pos < data.length() {
    let b = data.unsafe_get(pos).to_int()
    pos += 1
    result = result | ((b & 0x7F) << shift)
    if (b & 0x80) == 0 {
      return (result, pos)
    }
    shift += 7
    if shift >= 35 {
      raise SnappyError::CorruptInput("varint too long")
    }
  }
  raise SnappyError::UnexpectedEOF
}

///|
fn decode_block_prefix(
  src : BytesView,
  src_pos_ : Int,
  dst : FixedArray[Byte],
  uncompressed_len : Int,
) -> (Int, Bool) raise SnappyError {
  let mut src_pos = src_pos_
  let mut dst_pos = 0
  let src_len = src.length()
  while src_pos < src_len && dst_pos < uncompressed_len {
    let tag = src.unsafe_get(src_pos).to_int()
    let tag_type = tag & 0x03
    if tag_type == TAG_LITERAL {
      let mut lit_len = (tag >> 2) + 1
      src_pos += 1
      if lit_len == 61 {
        if src_pos >= src_len {
          return (dst_pos, false)
        }
        lit_len = src.unsafe_get(src_pos).to_int() + 1
        src_pos += 1
      } else if lit_len == 62 {
        if src_pos + 1 >= src_len {
          return (dst_pos, false)
        }
        lit_len = src.unsafe_get(src_pos).to_int() |
          (src.unsafe_get(src_pos + 1).to_int() << 8)
        lit_len += 1
        src_pos += 2
      } else if lit_len == 63 {
        if src_pos + 2 >= src_len {
          return (dst_pos, false)
        }
        lit_len = src.unsafe_get(src_pos).to_int() |
          (src.unsafe_get(src_pos + 1).to_int() << 8) |
          (src.unsafe_get(src_pos + 2).to_int() << 16)
        lit_len += 1
        src_pos += 3
      } else if lit_len == 64 {
        if src_pos + 3 >= src_len {
          return (dst_pos, false)
        }
        lit_len = src.unsafe_get(src_pos).to_int() |
          (src.unsafe_get(src_pos + 1).to_int() << 8) |
          (src.unsafe_get(src_pos + 2).to_int() << 16) |
          (src.unsafe_get(src_pos + 3).to_int() << 24)
        lit_len += 1
        src_pos += 4
      }
      if src_pos + lit_len > src_len {
        return (dst_pos, false)
      }
      guard dst_pos + lit_len <= uncompressed_len else {
        raise SnappyError::CorruptInput("literal extends past end of output")
      }
      for i in 0..<lit_len {
        dst.unsafe_set(dst_pos + i, src.unsafe_get(src_pos + i))
      }
      dst_pos += lit_len
      src_pos += lit_len
    } else if tag_type == TAG_COPY1 {
      src_pos += 1
      if src_pos >= src_len {
        return (dst_pos, false)
      }
      let length = ((tag >> 2) & 0x07) + 4
      let offset = (tag >> 5 << 8) | src.unsafe_get(src_pos).to_int()
      src_pos += 1
      guard offset > 0 && offset <= dst_pos else {
        raise SnappyError::CorruptInput("invalid copy offset \{offset}")
      }
      guard dst_pos + length <= uncompressed_len else {
        raise SnappyError::CorruptInput("copy extends past end of output")
      }
      let copy_start = dst_pos - offset
      for i in 0..<length {
        dst.unsafe_set(dst_pos + i, dst.unsafe_get(copy_start + i % offset))
      }
      dst_pos += length
    } else if tag_type == TAG_COPY2 {
      src_pos += 1
      if src_pos + 1 >= src_len {
        return (dst_pos, false)
      }
      let length = (tag >> 2) + 1
      let offset = src.unsafe_get(src_pos).to_int() |
        (src.unsafe_get(src_pos + 1).to_int() << 8)
      src_pos += 2
      guard offset > 0 && offset <= dst_pos else {
        raise SnappyError::CorruptInput("invalid copy offset \{offset}")
      }
      guard dst_pos + length <= uncompressed_len else {
        raise SnappyError::CorruptInput("copy extends past end of output")
      }
      let copy_start = dst_pos - offset
      for i in 0..<length {
        dst.unsafe_set(dst_pos + i, dst.unsafe_get(copy_start + i % offset))
      }
      dst_pos += length
    } else {
      src_pos += 1
      if src_pos + 3 >= src_len {
        return (dst_pos, false)
      }
      let length = (tag >> 2) + 1
      let offset = src.unsafe_get(src_pos).to_int() |
        (src.unsafe_get(src_pos + 1).to_int() << 8) |
        (src.unsafe_get(src_pos + 2).to_int() << 16) |
        (src.unsafe_get(src_pos + 3).to_int() << 24)
      src_pos += 4
      guard offset > 0 && offset <= dst_pos else {
        raise SnappyError::CorruptInput("invalid copy offset \{offset}")
      }
      guard dst_pos + length <= uncompressed_len else {
        raise SnappyError::CorruptInput("copy extends past end of output")
      }
      let copy_start = dst_pos - offset
      for i in 0..<length {
        dst.unsafe_set(dst_pos + i, dst.unsafe_get(copy_start + i % offset))
      }
      dst_pos += length
    }
  }
  if dst_pos == uncompressed_len {
    guard src_pos == src_len else {
      raise SnappyError::CorruptInput("trailing bytes after end of stream")
    }
    return (dst_pos, true)
  }
  (dst_pos, false)
}
