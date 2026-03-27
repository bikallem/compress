///|
/// Compresses data using the Snappy framed format.
pub fn compress_framed(data : Bytes) -> Bytes {
  let d = FramedDeflater::new()
  let out = @blit.Buffer::new(size_hint=data.length() + 32)
  let mut pos = 0
  while pos < data.length() {
    let end = if pos + SNAPPY_FRAMED_MAX_CHUNK < data.length() {
      pos + SNAPPY_FRAMED_MAX_CHUNK
    } else {
      data.length()
    }
    match d.encode(Some(data[pos:end])) {
      Data(chunk) => out.write_bytesview(chunk)
      Ok => ()
      End => ()
      Error(_) => ()
    }
    pos = end
  }
  loop d.encode(None) {
    Data(chunk) => {
      out.write_bytesview(chunk)
      continue d.encode(None)
    }
    End | Ok => break
    Error(_) => break
  }
  out.to_bytes()
}

///|
/// Decompresses data from the Snappy framed format.
pub fn decompress_framed(data : Bytes) -> Bytes raise SnappyError {
  let out = @blit.Buffer::new(size_hint=(data.length() * 2).max(256))
  let mut pos = 0
  let mut saw_stream_identifier = false
  while pos < data.length() {
    guard pos + 4 <= data.length() else { raise SnappyError::UnexpectedEOF }
    let chunk_type = data[pos].to_int()
    let chunk_len = data[pos + 1].to_int() |
      (data[pos + 2].to_int() << 8) |
      (data[pos + 3].to_int() << 16)
    pos += 4
    guard pos + chunk_len <= data.length() else {
      raise SnappyError::UnexpectedEOF
    }
    let payload = data[pos:pos + chunk_len]
    pos += chunk_len
    match chunk_type {
      SNAPPY_FRAME_STREAM_IDENTIFIER => {
        guard chunk_len == 6 && payload.to_bytes() == b"sNaPpY" else {
          raise SnappyError::CorruptInput("invalid Snappy stream identifier")
        }
        saw_stream_identifier = true
      }
      SNAPPY_FRAME_COMPRESSED => {
        guard saw_stream_identifier else {
          raise SnappyError::CorruptInput("missing Snappy stream identifier")
        }
        guard chunk_len >= 4 else { raise SnappyError::UnexpectedEOF }
        let expected = snappy_read_u32_le(payload.to_bytes(), 0).reinterpret_as_uint()
        let decoded = decompress(payload[4:].to_bytes())
        guard decoded.length() <= SNAPPY_FRAMED_MAX_CHUNK else {
          raise SnappyError::CorruptInput(
            "framed Snappy chunk exceeds 65536 bytes",
          )
        }
        let actual = snappy_mask_checksum(snappy_crc32c(decoded[:]))
        guard expected == actual else {
          raise SnappyError::CorruptInput(
            "framed Snappy chunk checksum mismatch",
          )
        }
        out.write_bytes(decoded)
      }
      SNAPPY_FRAME_UNCOMPRESSED => {
        guard saw_stream_identifier else {
          raise SnappyError::CorruptInput("missing Snappy stream identifier")
        }
        guard chunk_len >= 4 else { raise SnappyError::UnexpectedEOF }
        let raw_len = chunk_len - 4
        guard raw_len <= SNAPPY_FRAMED_MAX_CHUNK else {
          raise SnappyError::CorruptInput(
            "framed Snappy chunk exceeds 65536 bytes",
          )
        }
        let expected = snappy_read_u32_le(payload.to_bytes(), 0).reinterpret_as_uint()
        let raw = payload[4:].to_bytes()
        let actual = snappy_mask_checksum(snappy_crc32c(raw[:]))
        guard expected == actual else {
          raise SnappyError::CorruptInput(
            "framed Snappy chunk checksum mismatch",
          )
        }
        out.write_bytes(raw)
      }
      SNAPPY_FRAME_PADDING => ()
      _ =>
        if chunk_type >= 0x80 && chunk_type <= 0xFD {
          ()
        } else {
          raise SnappyError::CorruptInput(
            "unsupported Snappy framed chunk type \{chunk_type}",
          )
        }
    }
  }
  guard saw_stream_identifier else {
    raise SnappyError::CorruptInput("missing Snappy stream identifier")
  }
  out.to_bytes()
}

///|
priv struct FramedDeflaterState {
  mut header_emitted : Bool
  mut finished : Bool
}

///|
struct FramedDeflater(FramedDeflaterState)

///|
pub fn FramedDeflater::new() -> FramedDeflater {
  FramedDeflater({ header_emitted: false, finished: false })
}

///|
pub fn FramedDeflater::encode(
  self : FramedDeflater,
  data : BytesView?,
) -> Encode {
  let s = self.0
  if s.finished {
    return End
  }
  let out = @blit.Buffer::new()
  if !s.header_emitted {
    write_snappy_frame_chunk(out, SNAPPY_FRAME_STREAM_IDENTIFIER, b"sNaPpY")
    s.header_emitted = true
  }
  match data {
    Some(chunk) => {
      let mut pos = 0
      while pos < chunk.length() {
        let end = if pos + SNAPPY_FRAMED_MAX_CHUNK < chunk.length() {
          pos + SNAPPY_FRAMED_MAX_CHUNK
        } else {
          chunk.length()
        }
        write_snappy_frame_data_chunk(out, chunk[pos:end].to_bytes())
        pos = end
      }
      let bytes = out.to_bytes()
      if bytes.length() > 0 {
        Data(bytes[:])
      } else {
        Ok
      }
    }
    None => {
      s.finished = true
      let bytes = out.to_bytes()
      if bytes.length() > 0 {
        Data(bytes[:])
      } else {
        End
      }
    }
  }
}

///|
priv struct FramedInflaterState {
  mut buf : @blit.Buffer
  mut pos : Int
  mut saw_identifier : Bool
  mut finished : Bool
  mut failed : SnappyError?
}

///|
struct FramedInflater(FramedInflaterState)

///|
pub fn FramedInflater::new() -> FramedInflater {
  FramedInflater({
    buf: @blit.Buffer::new(),
    pos: 0,
    saw_identifier: false,
    finished: false,
    failed: None,
  })
}

///|
pub fn FramedInflater::src(self : FramedInflater, data : BytesView) -> Unit {
  let s = self.0
  if s.failed is Some(_) {
    return
  }
  s.buf.write_bytesview(data)
}

///|
pub fn FramedInflater::finish(self : FramedInflater) -> Unit {
  self.0.finished = true
}

///|
pub fn FramedInflater::decode(self : FramedInflater) -> Decode {
  let s = self.0
  match s.failed {
    Some(e) => return Error(e)
    None => ()
  }
  while true {
    let input = s.buf.to_bytes()
    let len = input.length()
    if s.pos + 4 > len {
      if s.finished {
        if s.pos >= len {
          if !s.saw_identifier {
            let err = SnappyError::CorruptInput(
              "missing Snappy stream identifier",
            )
            s.failed = Some(err)
            return Error(err)
          }
          return End
        }
        let err = SnappyError::CorruptInput(
          "truncated framed Snappy chunk header",
        )
        s.failed = Some(err)
        return Error(err)
      }
      return Await
    }
    let chunk_type = input[s.pos].to_int()
    let chunk_len = input[s.pos + 1].to_int() |
      (input[s.pos + 2].to_int() << 8) |
      (input[s.pos + 3].to_int() << 16)
    if s.pos + 4 + chunk_len > len {
      if s.finished {
        let err = SnappyError::CorruptInput("truncated framed Snappy chunk")
        s.failed = Some(err)
        return Error(err)
      }
      return Await
    }
    let payload_start = s.pos + 4
    s.pos = payload_start + chunk_len
    if s.pos > 65536 {
      let remaining = input.length() - s.pos
      let next = @blit.Buffer::new(size_hint=remaining)
      if remaining > 0 {
        next.write_bytesview(input[s.pos:])
      }
      s.buf = next
      s.pos = 0
    }
    match chunk_type {
      SNAPPY_FRAME_STREAM_IDENTIFIER => {
        if chunk_len != 6 ||
          input[payload_start:payload_start + chunk_len].to_bytes() !=
            b"sNaPpY" {
          let err = SnappyError::CorruptInput(
            "invalid Snappy stream identifier",
          )
          s.failed = Some(err)
          return Error(err)
        }
        s.saw_identifier = true
        continue
      }
      SNAPPY_FRAME_COMPRESSED => {
        if !s.saw_identifier {
          let err = SnappyError::CorruptInput(
            "missing Snappy stream identifier",
          )
          s.failed = Some(err)
          return Error(err)
        }
        if chunk_len < 4 {
          let err = SnappyError::CorruptInput("compressed chunk too short")
          s.failed = Some(err)
          return Error(err)
        }
        let expected = snappy_read_u32_le(
            input,
            payload_start,
          ).reinterpret_as_uint()
        let compressed_data = input[payload_start + 4:payload_start +
            chunk_len].to_bytes()
        let decoded = try {
          decompress(compressed_data)
        } catch {
          e => {
            let err = SnappyError::CorruptInput(e.to_string())
            s.failed = Some(err)
            return Error(err)
          }
        }
        if decoded.length() > SNAPPY_FRAMED_MAX_CHUNK {
          let err = SnappyError::CorruptInput(
            "framed Snappy chunk exceeds 65536 bytes",
          )
          s.failed = Some(err)
          return Error(err)
        }
        let actual = snappy_mask_checksum(snappy_crc32c(decoded[:]))
        if expected != actual {
          let err = SnappyError::CorruptInput(
            "framed Snappy chunk checksum mismatch",
          )
          s.failed = Some(err)
          return Error(err)
        }
        return Data(decoded[:])
      }
      SNAPPY_FRAME_UNCOMPRESSED => {
        if !s.saw_identifier {
          let err = SnappyError::CorruptInput(
            "missing Snappy stream identifier",
          )
          s.failed = Some(err)
          return Error(err)
        }
        if chunk_len < 4 {
          let err = SnappyError::CorruptInput("uncompressed chunk too short")
          s.failed = Some(err)
          return Error(err)
        }
        let raw_len = chunk_len - 4
        if raw_len > SNAPPY_FRAMED_MAX_CHUNK {
          let err = SnappyError::CorruptInput(
            "framed Snappy chunk exceeds 65536 bytes",
          )
          s.failed = Some(err)
          return Error(err)
        }
        let expected = snappy_read_u32_le(
            input,
            payload_start,
          ).reinterpret_as_uint()
        let raw = input[payload_start + 4:payload_start + chunk_len].to_bytes()
        let actual = snappy_mask_checksum(snappy_crc32c(raw[:]))
        if expected != actual {
          let err = SnappyError::CorruptInput(
            "framed Snappy chunk checksum mismatch",
          )
          s.failed = Some(err)
          return Error(err)
        }
        return Data(raw[:])
      }
      SNAPPY_FRAME_PADDING => continue
      _ =>
        if chunk_type >= 0x80 && chunk_type <= 0xFD {
          continue
        } else {
          let err = SnappyError::CorruptInput(
            "unsupported Snappy framed chunk type",
          )
          s.failed = Some(err)
          return Error(err)
        }
    }
  }
  End // unreachable
}

///|
const SNAPPY_FRAME_COMPRESSED : Int = 0x00

///|
const SNAPPY_FRAME_UNCOMPRESSED : Int = 0x01

///|
const SNAPPY_FRAME_PADDING : Int = 0xFE

///|
const SNAPPY_FRAME_STREAM_IDENTIFIER : Int = 0xFF

///|
const SNAPPY_FRAMED_MAX_CHUNK : Int = 65536

///|
const SNAPPY_CRC32C_POLY : UInt = 0x82F63B78U

///|
let snappy_crc32c_table : FixedArray[UInt] = {
  let table = FixedArray::make(256, 0U)
  for i in 0..<256 {
    let mut crc = i.reinterpret_as_uint()
    for _ in 0..<8 {
      if (crc & 1U) == 1U {
        crc = (crc >> 1) ^ SNAPPY_CRC32C_POLY
      } else {
        crc = crc >> 1
      }
    }
    table[i] = crc
  }
  table
}

///|
fn snappy_crc32c(data : BytesView) -> UInt {
  let mut crc = 0xFFFFFFFFU
  for i in 0..<data.length() {
    let idx = (crc ^ data.unsafe_get(i).to_uint()) & 0xFFU
    crc = snappy_crc32c_table[idx.reinterpret_as_int()] ^ (crc >> 8)
  }
  crc ^ 0xFFFFFFFFU
}

///|
fn snappy_mask_checksum(crc : UInt) -> UInt {
  ((crc >> 15) | (crc << 17)) + 0xA282EAD8U
}

///|
fn write_snappy_frame_chunk(
  out : @blit.Buffer,
  chunk_type : Int,
  payload : Bytes,
) -> Unit {
  out.write_byte(chunk_type.to_byte())
  let len = payload.length()
  out.write_byte((len & 0xFF).to_byte())
  out.write_byte(((len >> 8) & 0xFF).to_byte())
  out.write_byte(((len >> 16) & 0xFF).to_byte())
  out.write_bytes(payload)
}

///|
fn write_snappy_frame_data_chunk(out : @blit.Buffer, raw : Bytes) -> Unit {
  let checksum = snappy_mask_checksum(snappy_crc32c(raw[:]))
  let compressed = compress(raw)
  if compressed.length() < raw.length() {
    let payload = @blit.Buffer::new(size_hint=compressed.length() + 4)
    snappy_write_u32_le(payload, checksum)
    payload.write_bytes(compressed)
    write_snappy_frame_chunk(out, SNAPPY_FRAME_COMPRESSED, payload.to_bytes())
  } else {
    let payload = @blit.Buffer::new(size_hint=raw.length() + 4)
    snappy_write_u32_le(payload, checksum)
    payload.write_bytes(raw)
    write_snappy_frame_chunk(out, SNAPPY_FRAME_UNCOMPRESSED, payload.to_bytes())
  }
}

///|
fn snappy_write_u32_le(buf : @blit.Buffer, value : UInt) -> Unit {
  buf.write_byte((value & 0xFFU).to_byte())
  buf.write_byte(((value >> 8) & 0xFFU).to_byte())
  buf.write_byte(((value >> 16) & 0xFFU).to_byte())
  buf.write_byte(((value >> 24) & 0xFFU).to_byte())
}
