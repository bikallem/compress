///|
/// Bzip2Reader decompresses bzip2 data from a source `@stream.Reader`.
///
/// Implements `@stream.Reader` — pull-based, returns BytesView chunks.
pub struct Bzip2Reader {
  priv source : &@stream.Reader
  priv slice_length : Int
  priv mut output : Bytes
  priv mut output_offset : Int
  priv mut done : Bool
}

///|
pub fn Bzip2Reader::new(
  source : &@stream.Reader,
  slice_length? : Int = 65536,
) -> Bzip2Reader {
  {
    source,
    slice_length,
    output: Bytes::default(),
    output_offset: 0,
    done: false,
  }
}

///|
pub impl @stream.Reader for Bzip2Reader with read(self) {
  if self.done {
    return b""[:]
  }
  if self.output.length() == 0 && self.output_offset == 0 {
    let input = @stream.read_all(self.source) catch {
      e => raise @stream.StreamError::Format(e.to_string())
    }
    let decompressed = decompress(input) catch {
      e => raise @stream.StreamError::Format(e.to_string())
    }
    self.output = decompressed
  }
  if self.output_offset >= self.output.length() {
    self.done = true
    return b""[:]
  }
  let avail = self.output.length() - self.output_offset
  let n = if avail < self.slice_length { avail } else { self.slice_length }
  let view = self.output[self.output_offset:self.output_offset + n]
  self.output_offset += n
  view
}
