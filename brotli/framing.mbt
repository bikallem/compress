///|
let max_meta_block_len : Int = 1 << 24

///|
priv struct MetaBlockHeader {
  is_last : Bool
  is_last_empty : Bool
  is_metadata : Bool
  is_uncompressed : Bool
  length : Int
}

///|
fn bit_length(x : Int) -> Int {
  let mut value = x
  let mut bits = 0
  while value > 0 {
    value = value >> 1
    bits += 1
  }
  bits
}

///|
fn read_window_bits(reader : BitReader) -> Int? raise BrotliError {
  let snapshot = reader.snapshot()
  let value = match reader.read(1) {
    Some(0) => 16
    Some(_) =>
      match reader.read(3) {
        Some(n) =>
          if n != 0 {
            17 + n
          } else {
            match reader.read(3) {
              Some(0) => 17
              Some(1) => raise BrotliError::CorruptInput("invalid window bits")
              Some(m) => 8 + m
              None => {
                reader.restore(snapshot)
                return None
              }
            }
          }
        None => {
          reader.restore(snapshot)
          return None
        }
      }
    None => {
      reader.restore(snapshot)
      return None
    }
  }
  Some(value)
}

///|
fn read_meta_block_header(
  reader : BitReader,
) -> MetaBlockHeader? raise BrotliError {
  let snapshot = reader.snapshot()
  let is_last = match reader.read_bit() {
    Some(value) => value
    None => {
      reader.restore(snapshot)
      return None
    }
  }
  if is_last {
    let is_last_empty = match reader.read_bit() {
      Some(value) => value
      None => {
        reader.restore(snapshot)
        return None
      }
    }
    if is_last_empty {
      return Some({
        is_last: true,
        is_last_empty: true,
        is_metadata: false,
        is_uncompressed: false,
        length: 0,
      })
    }
  }
  let raw_nibbles = match reader.read(2) {
    Some(value) => value
    None => {
      reader.restore(snapshot)
      return None
    }
  }
  if raw_nibbles == 3 {
    match reader.read(1) {
      Some(0) => ()
      Some(_) => raise BrotliError::CorruptInput("reserved metablock bit set")
      None => {
        reader.restore(snapshot)
        return None
      }
    }
    let skip_bytes = match reader.read(2) {
      Some(value) => value
      None => {
        reader.restore(snapshot)
        return None
      }
    }
    let skip_len_minus_1 = if skip_bytes == 0 {
      0
    } else {
      match reader.read(skip_bytes * 8) {
        Some(value) => value
        None => {
          reader.restore(snapshot)
          return None
        }
      }
    }
    if skip_bytes > 1 {
      let high_byte = (skip_len_minus_1 >> ((skip_bytes - 1) * 8)) & 0xFF
      guard high_byte != 0 else {
        raise BrotliError::CorruptInput("non-minimal metadata length")
      }
    }
    reader.align_to_byte_zero()
    return Some({
      is_last,
      is_last_empty: false,
      is_metadata: true,
      is_uncompressed: false,
      length: skip_len_minus_1 + 1,
    })
  }
  let size_nibbles = raw_nibbles + 4
  let length_minus_1 = match reader.read(size_nibbles * 4) {
    Some(value) => value
    None => {
      reader.restore(snapshot)
      return None
    }
  }
  if size_nibbles > 4 {
    let high_nibble = (length_minus_1 >> ((size_nibbles - 1) * 4)) & 0xF
    guard high_nibble != 0 else {
      raise BrotliError::CorruptInput("non-minimal metablock length")
    }
  }
  let is_uncompressed = if is_last {
    false
  } else {
    match reader.read_bit() {
      Some(value) => value
      None => {
        reader.restore(snapshot)
        return None
      }
    }
  }
  Some({
    is_last,
    is_last_empty: false,
    is_metadata: false,
    is_uncompressed,
    length: length_minus_1 + 1,
  })
}

///|
fn write_window_bits(writer : BitWriter, wbits : Int) -> Unit raise BrotliError {
  if wbits == 16 {
    writer.write_bits(0U, 1)
    return
  }
  guard wbits >= 10 && wbits <= 24 else {
    raise BrotliError::CorruptInput("unsupported window bits")
  }
  if wbits == 17 {
    writer.write_bits(1U, 7)
  } else if wbits > 17 {
    let value = (((wbits - 17) << 1) | 1).reinterpret_as_uint()
    writer.write_bits(value, 4)
  } else {
    let value = (((wbits - 8) << 4) | 1).reinterpret_as_uint()
    writer.write_bits(value, 7)
  }
}

///|
fn write_meta_block_length(
  writer : BitWriter,
  length : Int,
) -> Unit raise BrotliError {
  guard length > 0 && length <= max_meta_block_len else {
    raise BrotliError::CorruptInput("invalid metablock length")
  }
  let lg = if length == 1 { 1 } else { bit_length(length - 1) }
  let mnibbles = if lg < 16 { 4 } else { (lg + 3) / 4 }
  writer.write_bits((mnibbles - 4).reinterpret_as_uint(), 2)
  writer.write_bits((length - 1).reinterpret_as_uint(), mnibbles * 4)
}

///|
fn write_metadata_block(
  writer : BitWriter,
  is_last : Bool,
  metadata : BytesView,
) -> Unit raise BrotliError {
  let len = metadata.length()
  guard len <= max_meta_block_len else {
    raise BrotliError::CorruptInput("metadata block too large")
  }
  writer.write_bits((if is_last { 1 } else { 0 }).reinterpret_as_uint(), 1)
  if is_last {
    writer.write_bits(0U, 1)
  }
  writer.write_bits(3U, 2)
  writer.write_bits(0U, 1)
  if len == 0 {
    writer.write_bits(0U, 2)
  } else {
    let nbytes = (bit_length(len - 1) + 7) / 8
    writer.write_bits(nbytes.reinterpret_as_uint(), 2)
    writer.write_bits((len - 1).reinterpret_as_uint(), nbytes * 8)
  }
  writer.align_to_byte()
  writer.write_bytes(metadata)
}

///|
fn write_uncompressed_block(
  writer : BitWriter,
  data : BytesView,
) -> Unit raise BrotliError {
  let len = data.length()
  guard len > 0 && len <= max_meta_block_len else {
    raise BrotliError::CorruptInput("invalid uncompressed block length")
  }
  writer.write_bits(0U, 1)
  write_meta_block_length(writer, len)
  writer.write_bits(1U, 1)
  writer.align_to_byte()
  writer.write_bytes(data)
}

///|
fn write_last_empty_block(writer : BitWriter) -> Unit {
  writer.write_bits(1U, 1)
  writer.write_bits(1U, 1)
}

///|
fn trivial_compress(data : Bytes) -> Bytes raise BrotliError {
  let writer = BitWriter::new(size_hint=data.length() + 16)
  write_window_bits(writer, 16)
  let mut offset = 0
  while offset < data.length() {
    let chunk_len = if data.length() - offset > max_meta_block_len {
      max_meta_block_len
    } else {
      data.length() - offset
    }
    write_uncompressed_block(writer, data[offset:offset + chunk_len])
    offset += chunk_len
  }
  write_last_empty_block(writer)
  writer.finish()
}
