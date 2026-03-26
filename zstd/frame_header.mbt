///|
priv struct ZstdFrameHeader {
  window_size : Int
  content_size : Int?
  dict_id : UInt
  has_checksum : Bool
}

///|
priv enum FrameHeaderParse {
  NeedMore
  Parsed(ZstdFrameHeader, Int)
  Skippable(Int)
  Error(ZstdError)
}

///|
fn read_u32_le(src : BytesView, pos : Int) -> UInt {
  src.unsafe_get(pos).to_uint() |
  (src.unsafe_get(pos + 1).to_uint() << 8) |
  (src.unsafe_get(pos + 2).to_uint() << 16) |
  (src.unsafe_get(pos + 3).to_uint() << 24)
}

///|
fn read_u64_low32_le(src : BytesView, pos : Int) -> Int {
  read_u32_le(src, pos).reinterpret_as_int()
}

///|
fn dict_id_field_size(dict_id : UInt) -> Int {
  if dict_id == 0U {
    return 0
  }
  if dict_id <= 0xFFU {
    return 1
  }
  if dict_id <= 0xFFFFU {
    return 2
  }
  4
}

///|
fn try_parse_frame_header(src : BytesView) -> FrameHeaderParse {
  if src.length() < 4 {
    return NeedMore
  }
  let magic = read_u32_le(src, 0)
  if (magic & ZSTD_MAGIC_SKIPPABLE_MASK) == ZSTD_MAGIC_SKIPPABLE_START {
    if src.length() < 8 {
      return NeedMore
    }
    let frame_size_u = read_u32_le(src, 4)
    if frame_size_u > 0x7FFFFFFFU {
      return Error(
        ZstdError::InvalidHeader("skippable frame size exceeds supported range"),
      )
    }
    return Skippable(8 + frame_size_u.reinterpret_as_int())
  }
  if magic != ZSTD_MAGIC {
    return Error(ZstdError::InvalidHeader("invalid magic number"))
  }
  if src.length() < 5 {
    return NeedMore
  }
  let fhd = src.unsafe_get(4).to_int()
  let fcs_flag = (fhd >> 6) & 0x03
  let single_segment = (fhd >> 5) & 0x01
  let reserved = (fhd >> 3) & 0x01
  let has_checksum = (fhd >> 2) & 0x01
  let dict_id_flag = fhd & 0x03
  if reserved != 0 {
    return Error(ZstdError::InvalidHeader("reserved frame header bit is set"))
  }
  let mut pos = 5
  let mut window_size = 0
  if single_segment == 0 {
    if pos >= src.length() {
      return NeedMore
    }
    let wd = src.unsafe_get(pos).to_int()
    pos += 1
    let exponent = (wd >> 3) + 10
    let mantissa = wd & 0x07
    window_size = (1 << exponent) + mantissa * (1 << (exponent - 3))
    if window_size > MAX_WINDOW_SIZE {
      return Error(
        ZstdError::WindowTooLarge("window size \{window_size} exceeds max"),
      )
    }
  }
  let dict_id_size = match dict_id_flag {
    0 => 0
    1 => 1
    2 => 2
    _ => 4
  }
  let fcs_size = match fcs_flag {
    0 => if single_segment == 1 { 1 } else { 0 }
    1 => 2
    2 => 4
    _ => 8
  }
  if pos + dict_id_size + fcs_size > src.length() {
    return NeedMore
  }
  let dict_id = match dict_id_size {
    0 => 0U
    1 => {
      let v = src.unsafe_get(pos).to_uint()
      pos += 1
      v
    }
    2 => {
      let v = src.unsafe_get(pos).to_uint() |
        (src.unsafe_get(pos + 1).to_uint() << 8)
      pos += 2
      v
    }
    _ => {
      let v = read_u32_le(src, pos)
      pos += 4
      v
    }
  }
  let content_size : Int? = match fcs_size {
    0 => None
    1 => {
      let v = src.unsafe_get(pos).to_int()
      pos += 1
      Some(v)
    }
    2 => {
      let v = src.unsafe_get(pos).to_int() |
        (src.unsafe_get(pos + 1).to_int() << 8)
      pos += 2
      Some(v + 256)
    }
    4 => {
      let v = read_u64_low32_le(src, pos)
      pos += 4
      Some(v)
    }
    _ => {
      let low = read_u64_low32_le(src, pos)
      let high = read_u64_low32_le(src, pos + 4)
      pos += 8
      if high != 0 {
        return Error(
          ZstdError::InvalidHeader("frame content size exceeds supported range"),
        )
      }
      Some(low)
    }
  }
  if single_segment == 1 {
    match content_size {
      Some(cs) => window_size = cs
      None => ()
    }
  }
  Parsed(
    { window_size, content_size, dict_id, has_checksum: has_checksum == 1 },
    pos,
  )
}

///|
fn write_le_value(
  dst : FixedArray[Byte],
  pos_ : Int,
  value : UInt,
  size : Int,
) -> Int {
  let mut pos = pos_
  for i in 0..<size {
    dst.unsafe_set(pos, ((value >> (i * 8)) & 0xFFU).to_byte())
    pos += 1
  }
  pos
}

///|
fn write_stream_le_value(dst : @blit.Buffer, value : UInt, size : Int) -> Unit {
  for i in 0..<size {
    dst.write_byte(((value >> (i * 8)) & 0xFFU).to_byte())
  }
}

///|
fn encode_window_descriptor(window_size : Int) -> Int {
  let clamped = if window_size <= 1024 { 1024 } else { window_size }
  for exponent in 0..<=30 {
    let base = 1 << (exponent + 10)
    let step = base >> 3
    for mantissa in 0..<=7 {
      if base + mantissa * step >= clamped {
        return (exponent << 3) | mantissa
      }
    }
  }
  0xFF
}

///|
fn write_zstd_frame_header(
  dst : FixedArray[Byte],
  pos_ : Int,
  content_size : Int,
  dict_id : UInt,
) -> Int {
  let mut pos = pos_
  let start = pos
  pos = write_le_value(dst, pos, ZSTD_MAGIC, 4)
  let (fcs_field, fcs_bytes) = if content_size == 0 {
    (0, 1)
  } else if content_size <= 255 {
    (0, 1)
  } else if content_size <= 65535 + 256 {
    (1, 2)
  } else {
    (2, 4)
  }
  let dict_id_bytes = dict_id_field_size(dict_id)
  let dict_id_flag = match dict_id_bytes {
    0 => 0
    1 => 1
    2 => 2
    _ => 3
  }
  let fhd = (fcs_field << 6) | (1 << 5) | 0x04 | dict_id_flag
  dst.unsafe_set(pos, fhd.to_byte())
  pos += 1
  pos = write_le_value(dst, pos, dict_id, dict_id_bytes)
  if fcs_bytes == 1 {
    dst.unsafe_set(pos, content_size.to_byte())
    pos += 1
  } else if fcs_bytes == 2 {
    let val = content_size - 256
    dst.unsafe_set(pos, (val & 0xFF).to_byte())
    dst.unsafe_set(pos + 1, ((val >> 8) & 0xFF).to_byte())
    pos += 2
  } else {
    dst.unsafe_set(pos, (content_size & 0xFF).to_byte())
    dst.unsafe_set(pos + 1, ((content_size >> 8) & 0xFF).to_byte())
    dst.unsafe_set(pos + 2, ((content_size >> 16) & 0xFF).to_byte())
    dst.unsafe_set(pos + 3, ((content_size >> 24) & 0xFF).to_byte())
    pos += 4
  }
  pos - start
}

///|
fn write_zstd_stream_header(
  dst : @blit.Buffer,
  window_size : Int,
  dict_id : UInt,
) -> Unit {
  write_stream_le_value(dst, ZSTD_MAGIC, 4)
  let dict_id_bytes = dict_id_field_size(dict_id)
  let dict_id_flag = match dict_id_bytes {
    0 => 0
    1 => 1
    2 => 2
    _ => 3
  }
  let fhd = dict_id_flag | 0x04
  dst.write_byte(fhd.to_byte())
  dst.write_byte(encode_window_descriptor(window_size).to_byte())
  write_stream_le_value(dst, dict_id, dict_id_bytes)
}
