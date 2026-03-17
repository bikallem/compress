///|
priv enum InflatePhase {
  StreamHeader
  MetaHeader
  Metadata(Int, Bool)
  Uncompressed(Int)
  Finalize
  Done
  Failed(BrotliError)
}

///|
/// Streaming Brotli decompressor.
struct Inflater {
  mut phase : InflatePhase
  br : BitReader
  mut sink : @output_sink.OutputSink?
}

///|
pub fn Inflater::new() -> Inflater {
  { phase: StreamHeader, br: BitReader::new(), sink: None }
}

///|
pub fn Inflater::src(self : Inflater, data : BytesView) -> Unit {
  self.br.set_input(data)
}

///|
pub fn Inflater::decode(self : Inflater) -> Decode {
  match self.phase {
    StreamHeader => {
      let result = try? read_window_bits(self.br)
      match result {
        Ok(Some(_wbits)) => {
          self.phase = MetaHeader
          self.decode()
        }
        Ok(None) => Await
        Err(e) => self.fail(e)
      }
    }
    MetaHeader => {
      let result = try? read_meta_block_header(self.br)
      match result {
        Ok(Some(header)) => {
          if header.is_last_empty {
            self.phase = Finalize
            return self.decode()
          }
          if header.is_metadata {
            self.phase = Metadata(header.length, header.is_last)
            return self.decode()
          }
          if header.is_uncompressed {
            let aligned = try? self.br.align_to_byte_zero()
            match aligned {
              Ok(_) => {
                self.phase = Uncompressed(header.length)
                return self.decode()
              }
              Err(e) => return self.fail(e)
            }
          }
          self.fail(
            BrotliError::UnsupportedFeature(
              "compressed metablocks not implemented",
            ),
          )
        }
        Ok(None) => Await
        Err(e) => self.fail(e)
      }
    }
    Metadata(remaining, is_last) => {
      let skipped = self.br.read_aligned_bytes(remaining)
      if skipped.length() == 0 {
        return Await
      }
      let next_remaining = remaining - skipped.length()
      self.phase = if next_remaining == 0 {
        if is_last {
          Finalize
        } else {
          MetaHeader
        }
      } else {
        Metadata(next_remaining, is_last)
      }
      self.decode()
    }
    Uncompressed(remaining) => {
      let chunk = self.br.read_aligned_bytes(
        if remaining < 32768 {
          remaining
        } else {
          32768
        },
      )
      if chunk.length() == 0 {
        return Await
      }
      let next_remaining = remaining - chunk.length()
      self.phase = if next_remaining == 0 {
        MetaHeader
      } else {
        Uncompressed(next_remaining)
      }
      match self.sink {
        Some(sink) => {
          sink.write_bytes(chunk)
          self.decode()
        }
        None => Data(chunk)
      }
    }
    Finalize => {
      let aligned = try? self.br.align_to_byte_zero()
      match aligned {
        Ok(_) => {
          self.phase = Done
          End
        }
        Err(e) => self.fail(e)
      }
    }
    Done => End
    Failed(e) => Error(e)
  }
}

///|
pub fn Inflater::remaining(self : Inflater) -> Bytes {
  self.br.remaining_bytes()
}

///|
fn Inflater::enable_direct_output(self : Inflater, capacity : Int) -> Unit {
  self.sink = Some(@output_sink.OutputSink::new(capacity))
}

///|
fn Inflater::take_output(self : Inflater) -> Bytes {
  match self.sink {
    Some(sink) => sink.to_bytes()
    None => Bytes::default()
  }
}

///|
fn Inflater::fail(self : Inflater, e : BrotliError) -> Decode {
  self.phase = Failed(e)
  Error(e)
}
