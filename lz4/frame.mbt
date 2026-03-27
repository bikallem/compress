///|
priv struct Lz4FrameHeader {
  data_offset : Int
  content_size : Int?
  has_content_checksum : Bool
  has_block_checksum : Bool
  block_max_size : Int
  block_independence : Bool
  dict_id : UInt
}

///|
fn write_u64_le(dst : FixedArray[Byte], pos : Int, value : UInt64) -> Unit {
  dst.unsafe_set(pos, (value & 0xFFUL).to_uint().to_byte())
  dst.unsafe_set(pos + 1, ((value >> 8) & 0xFFUL).to_uint().to_byte())
  dst.unsafe_set(pos + 2, ((value >> 16) & 0xFFUL).to_uint().to_byte())
  dst.unsafe_set(pos + 3, ((value >> 24) & 0xFFUL).to_uint().to_byte())
  dst.unsafe_set(pos + 4, ((value >> 32) & 0xFFUL).to_uint().to_byte())
  dst.unsafe_set(pos + 5, ((value >> 40) & 0xFFUL).to_uint().to_byte())
  dst.unsafe_set(pos + 6, ((value >> 48) & 0xFFUL).to_uint().to_byte())
  dst.unsafe_set(pos + 7, ((value >> 56) & 0xFFUL).to_uint().to_byte())
}

///|
/// Writes an LZ4 frame header to the output buffer.
/// Returns the number of bytes written.
fn write_frame_header(
  dst : FixedArray[Byte],
  pos_ : Int,
  content_size : Int?,
  options : FrameOptions,
) -> Int {
  let mut pos = pos_
  let start = pos
  // Magic number (little-endian)
  dst.unsafe_set(pos, (LZ4_FRAME_MAGIC & 0xFFU).to_byte())
  dst.unsafe_set(pos + 1, ((LZ4_FRAME_MAGIC >> 8) & 0xFFU).to_byte())
  dst.unsafe_set(pos + 2, ((LZ4_FRAME_MAGIC >> 16) & 0xFFU).to_byte())
  dst.unsafe_set(pos + 3, ((LZ4_FRAME_MAGIC >> 24) & 0xFFU).to_byte())
  pos += 4
  let has_content_size = content_size is Some(_)
  let flg = 0x40 |
    (if options.block_independence { 0x20 } else { 0 }) |
    (if options.block_checksum { 0x10 } else { 0 }) |
    (if has_content_size { 0x08 } else { 0 }) |
    (if options.content_checksum { 0x04 } else { 0 }) |
    (if options.dict_id != 0U { 0x01 } else { 0 })
  dst.unsafe_set(pos, flg.to_byte())
  pos += 1
  let bd = block_max_size_id(options.block_max_size) << 4
  dst.unsafe_set(pos, bd.to_byte())
  pos += 1
  // Optional content size (8 bytes, little-endian)
  match content_size {
    Some(size) => {
      write_u64_le(dst, pos, size.reinterpret_as_uint().to_uint64())
      pos += 8
    }
    None => ()
  }
  if options.dict_id != 0U {
    dst.unsafe_set(pos, (options.dict_id & 0xFFU).to_byte())
    dst.unsafe_set(pos + 1, ((options.dict_id >> 8) & 0xFFU).to_byte())
    dst.unsafe_set(pos + 2, ((options.dict_id >> 16) & 0xFFU).to_byte())
    dst.unsafe_set(pos + 3, ((options.dict_id >> 24) & 0xFFU).to_byte())
    pos += 4
  }
  // Header checksum: (xxh32(header_bytes) >> 8) & 0xFF
  let header_start = start + 4 // after magic
  let header_len = pos - header_start
  let header_bytes = Bytes::makei(header_len, fn(i) {
    dst.unsafe_get(header_start + i)
  })
  let hc = @checksum.xxh32(header_bytes[:])
  dst.unsafe_set(pos, ((hc >> 8) & 0xFFU).to_byte())
  pos += 1
  pos - start
}

///|
fn frame_header_length(content_size : Int?, options : FrameOptions) -> Int {
  4 +
  1 +
  1 +
  (if content_size is Some(_) { 8 } else { 0 }) +
  (if options.dict_id != 0U { 4 } else { 0 }) +
  1
}

///|
/// Writes the end mark (4 zero bytes) and optional content checksum.
/// Returns bytes written.
fn write_frame_footer(
  dst : FixedArray[Byte],
  pos_ : Int,
  content_checksum : UInt?,
) -> Int {
  let mut pos = pos_
  let start = pos
  // End mark: 0x00000000
  dst.unsafe_set(pos, b'\x00')
  dst.unsafe_set(pos + 1, b'\x00')
  dst.unsafe_set(pos + 2, b'\x00')
  dst.unsafe_set(pos + 3, b'\x00')
  pos += 4
  // Content checksum (XXH32 of original data)
  match content_checksum {
    Some(cs) => {
      dst.unsafe_set(pos, (cs & 0xFFU).to_byte())
      dst.unsafe_set(pos + 1, ((cs >> 8) & 0xFFU).to_byte())
      dst.unsafe_set(pos + 2, ((cs >> 16) & 0xFFU).to_byte())
      dst.unsafe_set(pos + 3, ((cs >> 24) & 0xFFU).to_byte())
      pos += 4
    }
    None => ()
  }
  pos - start
}

///|
/// Parses an LZ4 frame header.
fn parse_frame_header(data : BytesView) -> Lz4FrameHeader raise Lz4Error {
  guard data.length() >= 7 else {
    raise Lz4Error::InvalidHeader("frame too short")
  }
  // Check magic
  let magic = data.unsafe_get(0).to_uint() |
    (data.unsafe_get(1).to_uint() << 8) |
    (data.unsafe_get(2).to_uint() << 16) |
    (data.unsafe_get(3).to_uint() << 24)
  guard magic == LZ4_FRAME_MAGIC else {
    raise Lz4Error::InvalidHeader("invalid magic number")
  }
  let flg = data.unsafe_get(4).to_int()
  let version = (flg >> 6) & 0x03
  guard version == 1 else {
    raise Lz4Error::InvalidHeader("unsupported version")
  }
  let block_independence = (flg & 0x20) != 0
  let has_block_checksum = (flg & 0x10) != 0
  let has_content_size = (flg & 0x08) != 0
  let has_content_checksum = (flg & 0x04) != 0
  let has_dict_id = (flg & 0x01) != 0
  guard (flg & 0x02) == 0 else {
    raise Lz4Error::InvalidHeader("reserved FLG bit set")
  }
  let bd = data.unsafe_get(5).to_int()
  guard (bd & 0x8F) == 0 else {
    raise Lz4Error::InvalidHeader("reserved BD bits set")
  }
  let block_max_size_id = (bd >> 4) & 0x07
  guard block_max_size_id >= 4 && block_max_size_id <= 7 else {
    raise Lz4Error::InvalidHeader("invalid block max size id")
  }
  let block_max_size = max_block_sizes[block_max_size_id]
  let mut pos = 6
  let content_size : Int? = if has_content_size {
    guard pos + 8 <= data.length() else { raise Lz4Error::UnexpectedEOF }
    let size = lz4_read_content_size(data, pos)
    pos += 8
    Some(size)
  } else {
    None
  }
  let dict_id = if has_dict_id {
    guard pos + 4 <= data.length() else { raise Lz4Error::UnexpectedEOF }
    let dict_id = data.unsafe_get(pos).to_uint() |
      (data.unsafe_get(pos + 1).to_uint() << 8) |
      (data.unsafe_get(pos + 2).to_uint() << 16) |
      (data.unsafe_get(pos + 3).to_uint() << 24)
    pos += 4
    dict_id
  } else {
    0U
  }
  // Verify header checksum
  let header_start = 4 // after magic
  let header_len = pos - header_start
  let header_bytes = Bytes::makei(header_len, fn(i) {
    data.unsafe_get(header_start + i)
  })
  let expected_hc = (@checksum.xxh32(header_bytes[:]) >> 8) & 0xFFU
  guard pos < data.length() else { raise Lz4Error::UnexpectedEOF }
  let actual_hc = data.unsafe_get(pos).to_uint()
  guard expected_hc == actual_hc else {
    raise Lz4Error::ChecksumMismatch(expected=expected_hc, got=actual_hc)
  }
  pos += 1
  {
    data_offset: pos,
    content_size,
    has_content_checksum,
    has_block_checksum,
    block_max_size,
    block_independence,
    dict_id,
  }
}
