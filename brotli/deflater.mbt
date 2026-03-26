///|
/// Incremental Brotli compressor using signal protocol.
priv struct EncoderState {
  level : CompressionLevel
  bw : BitWriter
  mut header_written : Bool
  mut finished : Bool
}

///|
struct Deflater(EncoderState)

///|
pub fn Deflater::new(level? : CompressionLevel = Default) -> Deflater {
  Deflater({
    level,
    bw: BitWriter::new(1024),
    header_written: false,
    finished: false,
  })
}

///|
pub fn Deflater::encode(self : Deflater, data : BytesView?) -> Encode {
  let s = self.0
  if s.finished {
    return End
  }
  match data {
    Some(chunk) => {
      if chunk.length() == 0 {
        return Ok
      }
      if !s.header_written {
        encode_wbits(s.bw, 22)
        s.header_written = true
      }
      encode_stream_chunk_into(
        s.bw,
        chunk,
        chunk.length(),
        compression_level_to_int(s.level),
        false,
      )
      let out = s.bw.take_output()
      if out.length() > 0 {
        Data(out[:])
      } else {
        Ok
      }
    }
    None => {
      s.finished = true
      if !s.header_written {
        let out = compress_empty()
        return if out.length() > 0 { Data(out[:]) } else { End }
      }
      s.bw.write_bits(1, 1)
      s.bw.write_bits(1, 1)
      let out = s.bw.take_output_final()
      if out.length() > 0 {
        Data(out[:])
      } else {
        End
      }
    }
  }
}
