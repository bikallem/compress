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
/// Reads a varint from data starting at pos. Returns (value, new_pos).
fn read_varint(data : BytesView, pos_ : Int) -> (Int, Int) raise SnappyError {
  let mut pos = pos_
  let mut result = 0
  let mut shift = 0
  while pos < data.length() {
    let b = data[pos].to_int()
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
/// Decompresses a Snappy stream from src into dst. Returns bytes written.
fn decode_block(
  src : BytesView,
  src_pos_ : Int,
  dst : FixedArray[Byte],
  uncompressed_len : Int,
) -> Int raise SnappyError {
  let mut src_pos = src_pos_
  let mut dst_pos = 0
  let src_len = src.length()
  while src_pos < src_len && dst_pos < uncompressed_len {
    let tag = src[src_pos].to_int()
    let tag_type = tag & 0x03
    if tag_type == TAG_LITERAL {
      let mut lit_len = (tag >> 2) + 1
      src_pos += 1
      if lit_len == 61 {
        guard src_pos < src_len else { raise SnappyError::UnexpectedEOF }
        lit_len = src[src_pos].to_int() + 1
        src_pos += 1
      } else if lit_len == 62 {
        guard src_pos + 1 < src_len else { raise SnappyError::UnexpectedEOF }
        lit_len = src[src_pos].to_int() | (src[src_pos + 1].to_int() << 8)
        lit_len += 1
        src_pos += 2
      } else if lit_len == 63 {
        guard src_pos + 2 < src_len else { raise SnappyError::UnexpectedEOF }
        lit_len = src[src_pos].to_int() |
          (src[src_pos + 1].to_int() << 8) |
          (src[src_pos + 2].to_int() << 16)
        lit_len += 1
        src_pos += 3
      } else if lit_len == 64 {
        guard src_pos + 3 < src_len else { raise SnappyError::UnexpectedEOF }
        lit_len = src[src_pos].to_int() |
          (src[src_pos + 1].to_int() << 8) |
          (src[src_pos + 2].to_int() << 16) |
          (src[src_pos + 3].to_int() << 24)
        lit_len += 1
        src_pos += 4
      }
      guard src_pos + lit_len <= src_len else {
        raise SnappyError::UnexpectedEOF
      }
      guard dst_pos + lit_len <= uncompressed_len else {
        raise SnappyError::CorruptInput("literal extends past end of output")
      }
      for i in 0..<lit_len {
        dst[dst_pos + i] = src[src_pos + i]
      }
      dst_pos += lit_len
      src_pos += lit_len
    } else if tag_type == TAG_COPY1 {
      // 2-byte copy: offset in bits 5-7 of tag + next byte, length in bits 2-4 + 4
      src_pos += 1
      guard src_pos < src_len else { raise SnappyError::UnexpectedEOF }
      let length = ((tag >> 2) & 0x07) + 4
      let offset = (tag >> 5 << 8) | src[src_pos].to_int()
      src_pos += 1
      guard offset > 0 && offset <= dst_pos else {
        raise SnappyError::CorruptInput("invalid copy offset \{offset}")
      }
      guard dst_pos + length <= uncompressed_len else {
        raise SnappyError::CorruptInput("copy extends past end of output")
      }
      let copy_start = dst_pos - offset
      for i in 0..<length {
        dst[dst_pos + i] = dst[copy_start + i % offset]
      }
      dst_pos += length
    } else if tag_type == TAG_COPY2 {
      // 3-byte copy: 16-bit offset, length in bits 2-7 + 1
      src_pos += 1
      guard src_pos + 1 < src_len else { raise SnappyError::UnexpectedEOF }
      let length = (tag >> 2) + 1
      let offset = src[src_pos].to_int() | (src[src_pos + 1].to_int() << 8)
      src_pos += 2
      guard offset > 0 && offset <= dst_pos else {
        raise SnappyError::CorruptInput("invalid copy offset \{offset}")
      }
      guard dst_pos + length <= uncompressed_len else {
        raise SnappyError::CorruptInput("copy extends past end of output")
      }
      let copy_start = dst_pos - offset
      for i in 0..<length {
        dst[dst_pos + i] = dst[copy_start + i % offset]
      }
      dst_pos += length
    } else {
      // TAG_COPY4: 5-byte copy with 32-bit offset
      src_pos += 1
      guard src_pos + 3 < src_len else { raise SnappyError::UnexpectedEOF }
      let length = (tag >> 2) + 1
      let offset = src[src_pos].to_int() |
        (src[src_pos + 1].to_int() << 8) |
        (src[src_pos + 2].to_int() << 16) |
        (src[src_pos + 3].to_int() << 24)
      src_pos += 4
      guard offset > 0 && offset <= dst_pos else {
        raise SnappyError::CorruptInput("invalid copy offset \{offset}")
      }
      guard dst_pos + length <= uncompressed_len else {
        raise SnappyError::CorruptInput("copy extends past end of output")
      }
      let copy_start = dst_pos - offset
      for i in 0..<length {
        dst[dst_pos + i] = dst[copy_start + i % offset]
      }
      dst_pos += length
    }
  }
  guard dst_pos == uncompressed_len else {
    raise SnappyError::CorruptInput(
      "decoded \{dst_pos} bytes, expected \{uncompressed_len}",
    )
  }
  dst_pos
}
