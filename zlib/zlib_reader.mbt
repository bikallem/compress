///|
/// ZlibReader decompresses zlib data from a source `@stream.Reader`.
///
/// Implements `@stream.Reader` — pull-based, returns BytesView chunks.
pub struct ZlibReader {
  priv source : &@stream.Reader
  priv dict : Bytes
  priv slice_length : Int
  priv mut output : Bytes
  priv mut output_offset : Int
  priv mut done : Bool
}

///|
pub fn ZlibReader::new(
  source : &@stream.Reader,
  dict? : Bytes = Bytes::default(),
  slice_length? : Int = 65536,
) -> ZlibReader {
  {
    source,
    dict,
    slice_length,
    output: Bytes::default(),
    output_offset: 0,
    done: false,
  }
}

///|
pub impl @stream.Reader for ZlibReader with read(self) {
  if self.done {
    return b""[:]
  }
  if self.output.length() == 0 && self.output_offset == 0 {
    let input = @stream.read_all(self.source) catch {
      e => raise @stream.StreamError::Format(e.to_string())
    }
    let decompressed = decompress_with_dict(input, self.dict) catch {
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
