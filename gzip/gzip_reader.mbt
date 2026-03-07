///|
/// GzipReader decompresses gzip data from a source `@stream.Reader`.
///
/// Implements `@stream.Reader` — pull-based, returns BytesView chunks.
/// Also exposes the parsed gzip Header after decompression.
pub struct GzipReader {
  priv source : &@stream.Reader
  priv slice_length : Int
  priv mut output : Bytes
  priv mut output_offset : Int
  priv mut header : Header
  priv mut done : Bool
}

///|
pub fn GzipReader::new(
  source : &@stream.Reader,
  slice_length? : Int = 65536,
) -> GzipReader {
  {
    source,
    slice_length,
    output: Bytes::default(),
    output_offset: 0,
    header: Header::default(),
    done: false,
  }
}

///|
/// Returns the parsed gzip header. Only valid after at least one `read()`.
pub fn GzipReader::header(self : GzipReader) -> Header {
  self.header
}

///|
pub impl @stream.Reader for GzipReader with read(self) {
  if self.done {
    return b""[:]
  }
  if self.output.length() == 0 && self.output_offset == 0 {
    let input = @stream.read_all(self.source) catch {
      e => raise @stream.StreamError::Format(e.to_string())
    }
    let (decompressed, hdr) = decompress(input) catch {
      e => raise @stream.StreamError::Format(e.to_string())
    }
    self.output = decompressed
    self.header = hdr
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
