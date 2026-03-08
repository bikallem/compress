///|
/// Reads all data from an `@io.Reader` into a `@stream.BytesReader`.
///
/// This buffers the entire input — use when the async source must be
/// fully consumed before sync processing can begin.
pub async fn reader_of_io(
  source : &@io.Reader,
  slice_length? : Int = 65536,
) -> @stream.BytesReader {
  let data = source.read_all().binary()
  @stream.BytesReader::new(data, slice_length~)
}

///|
/// Writes all data from a `@stream.Reader` to an `@io.Writer`.
///
/// Drains the sync reader and pushes chunks to the async writer.
pub async fn write_to_io(reader : &@stream.Reader, dest : &@io.Writer) -> Unit {
  while true {
    let chunk = reader.read()
    if chunk.is_empty() {
      break
    }
    let bytes = bytes_of_view(chunk)
    let mut offset = 0
    while offset < bytes.length() {
      let n = dest.write_once(bytes, offset~, len=bytes.length() - offset)
      offset += n
    }
  }
}

///|
/// Reads from an `@io.Reader`, pushes through a sync `@stream.Writer` filter,
/// and writes the filtered output to an `@io.Writer`.
///
/// The `filter` receives a `BufferWriter` sink and returns a `@stream.Writer`
/// that transforms data before forwarding to the sink. After all data is
/// processed, the sink's contents are written to `dest`.
///
/// Example — compress from async reader to async writer:
/// ```mbt nocheck
/// pipe_async(source, dest, fn(sink) { @flate.DeflateWriter::new(sink) })
/// ```
pub async fn pipe_async(
  source : &@io.Reader,
  dest : &@io.Writer,
  filter : (&@stream.Writer) -> &@stream.Writer,
  slice_length? : Int = 65536,
) -> Unit {
  let sink = @stream.BufferWriter::new()
  let filtered = filter(sink)
  let buf = FixedArray::make(slice_length, b'\x00')
  while true {
    let n = source.read(buf)
    if n == 0 {
      break
    }
    filtered.write(buf.unsafe_reinterpret_as_bytes()[0:n])
  }
  // Signal eod to flush the filter chain
  filtered.write(b""[:])
  // Write collected output to async dest
  let output = sink.to_bytes()
  let mut offset = 0
  while offset < output.length() {
    let n = dest.write_once(output, offset~, len=output.length() - offset)
    offset += n
  }
}

///|
fn bytes_of_view(view : BytesView) -> Bytes {
  let buf = @buffer.new(size_hint=view.length())
  for i in 0..<view.length() {
    buf.write_byte(view[i])
  }
  buf.to_bytes()
}
