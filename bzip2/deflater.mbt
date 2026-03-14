///|
/// Streaming bzip2 compressor using signal protocol.
///
/// Compresses block-by-block with O(block_size) memory. Full blocks
/// are emitted as soon as the input buffer fills to block_size bytes.
///
/// Usage:
///   let d = Deflater::new()
///   match d.encode(Some(data)) { Ok => ...; Data(out) => ... }
///   match d.encode(None) { Data(out) => ...; End => ... }
priv struct Encoder {
  level : Int
  block_size : Int
  bw : Bzip2BitWriter
  block_buf : FixedArray[Byte]
  mut block_len : Int
  mut stream_crc : UInt
  mut header_written : Bool
  mut finished : Bool
}

///|
struct Deflater(Encoder)

///|
pub fn Deflater::new(level? : Int = 9) -> Deflater raise Bzip2Error {
  guard level >= 1 && level <= 9 else {
    raise Bzip2Error::CorruptData("invalid bzip2 level: must be 1-9")
  }
  let block_size = level * 100000
  Deflater({
    level,
    block_size,
    bw: Bzip2BitWriter::new(size_hint=block_size),
    block_buf: FixedArray::make(block_size, b'\x00'),
    block_len: 0,
    stream_crc: 0U,
    header_written: false,
    finished: false,
  })
}

///|
pub fn Deflater::encode(self : Deflater, data : Bytes?) -> Encode {
  let s = self.0
  if s.finished {
    return End
  }
  match data {
    Some(chunk) => {
      if !s.header_written {
        write_stream_header(s)
      }
      // Feed chunk into block buffer, compressing full blocks
      let mut offset = 0
      let mut blocks_flushed = false
      while offset < chunk.length() {
        let space = s.block_size - s.block_len
        let n = if chunk.length() - offset < space {
          chunk.length() - offset
        } else {
          space
        }
        for i in 0..<n {
          s.block_buf[s.block_len + i] = chunk[offset + i]
        }
        s.block_len += n
        offset += n
        if s.block_len == s.block_size {
          flush_block(s)
          blocks_flushed = true
        }
      }
      // Only emit output when full blocks were compressed
      if blocks_flushed {
        let output = s.bw.take_output()
        if output.length() > 0 {
          Data(output)
        } else {
          Ok
        }
      } else {
        Ok
      }
    }
    None => {
      if !s.header_written {
        write_stream_header(s)
      }
      // Compress remaining block data
      if s.block_len > 0 {
        flush_block(s)
      }
      // Write end-of-stream marker + stream CRC
      s.bw.write_bits(0x177245U, 24)
      s.bw.write_bits(0x385090U, 24)
      s.bw.write_bits(s.stream_crc >> 16, 16)
      s.bw.write_bits(s.stream_crc & 0xFFFFU, 16)
      s.bw.flush()
      s.finished = true
      let output = s.bw.take_output()
      if output.length() > 0 {
        Data(output)
      } else {
        End
      }
    }
  }
}

///|
fn write_stream_header(s : Encoder) -> Unit {
  s.bw.write_byte(BZIP2_MAGIC1)
  s.bw.write_byte(BZIP2_MAGIC2)
  s.bw.write_byte(b'h')
  s.bw.write_byte((b'0'.to_int() + s.level).to_byte())
  s.header_written = true
}

///|
fn flush_block(s : Encoder) -> Unit {
  let block_data = Bytes::makei(s.block_len, fn(i) { s.block_buf[i] })
  let block_crc = compress_block(s.bw, block_data, 0, s.block_len)
  s.stream_crc = ((s.stream_crc << 1) | (s.stream_crc >> 31)) ^ block_crc
  s.block_len = 0
}
