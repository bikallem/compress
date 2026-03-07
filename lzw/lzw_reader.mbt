///|
/// LzwReader decompresses LZW data from a source `@stream.Reader`.
///
/// Implements `@stream.Reader` — pull-based, returns BytesView chunks.
pub struct LzwReader {
  priv source : &@stream.Reader
  priv order : BitOrder
  priv lit_width : Int
  priv slice_length : Int
  priv mut output : Bytes
  priv mut output_offset : Int
  priv mut done : Bool
}

///|
pub fn LzwReader::new(
  source : &@stream.Reader,
  order : BitOrder,
  lit_width : Int,
  slice_length? : Int = 65536,
) -> LzwReader {
  {
    source,
    order,
    lit_width,
    slice_length,
    output: Bytes::default(),
    output_offset: 0,
    done: false,
  }
}

///|
pub impl @stream.Reader for LzwReader with read(self) {
  if self.done {
    return b""[:]
  }
  if self.output.length() == 0 && self.output_offset == 0 {
    let input = @stream.read_all(self.source) catch {
      e => raise @stream.StreamError::Format(e.to_string())
    }
    let decompressed = decompress(input, self.order, self.lit_width) catch {
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
