///|
/// InflateReader decompresses DEFLATE data from a source `@stream.Reader`.
///
/// Implements `@stream.Reader` — pull-based, returns BytesView chunks.
/// Decompresses incrementally from the source stream.
pub struct InflateReader {
  priv source : &@stream.Reader
  priv dict : Bytes
  priv slice_length : Int
  priv mut output : Bytes
  priv mut output_offset : Int
  priv mut remaining : Bytes
  priv mut done : Bool
}

///|
pub fn InflateReader::new(
  source : &@stream.Reader,
  dict? : Bytes = Bytes::default(),
  slice_length? : Int = 65536,
) -> InflateReader {
  {
    source,
    dict,
    slice_length,
    output: Bytes::default(),
    output_offset: 0,
    remaining: Bytes::default(),
    done: false,
  }
}

///|
/// Returns any bytes read from source but not consumed by DEFLATE.
pub fn InflateReader::remaining(self : InflateReader) -> Bytes {
  self.remaining
}

///|
pub impl @stream.Reader for InflateReader with read(self) {
  if self.done {
    return b""[:]
  }
  // Lazy decompression: decompress on first read
  if self.output.length() == 0 && self.output_offset == 0 {
    let (decompressed, rem) = decompress_reader(self.source, self.dict) catch {
      e => raise @stream.StreamError::Format(e.to_string())
    }
    self.output = decompressed
    self.remaining = rem
  }
  // Yield output in slice_length-bounded chunks
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
