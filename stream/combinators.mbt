///|
/// Wraps a `&Reader` with 1-element push_back for header sniffing.
struct Buffered {
  inner : &Reader
  mut pushed_back : BytesView?
}

///|
pub fn Buffered::new(reader : &Reader) -> Buffered {
  { inner: reader, pushed_back: None }
}

///|
pub fn Buffered::push_back(self : Buffered, slice : BytesView) -> Unit {
  self.pushed_back = Some(slice)
}

///|
pub impl Reader for Buffered with read(self) {
  match self.pushed_back {
    Some(slice) => {
      self.pushed_back = None
      slice
    }
    None => self.inner.read()
  }
}

///|
/// Limits reads to the first `n` bytes.
struct LimitReader {
  inner : &Reader
  mut remaining : Int
}

///|
pub fn LimitReader::new(reader : &Reader, n : Int) -> LimitReader {
  { inner: reader, remaining: n }
}

///|
pub impl Reader for LimitReader with read(self) {
  if self.remaining <= 0 {
    return b""[:]
  }
  let chunk = self.inner.read()
  if chunk.is_empty() {
    return chunk
  }
  let n = if chunk.length() < self.remaining {
    chunk.length()
  } else {
    self.remaining
  }
  self.remaining -= n
  chunk[0:n]
}

///|
/// Concatenates two readers sequentially.
struct AppendReader {
  first : &Reader
  second : &Reader
  mut use_second : Bool
}

///|
pub fn AppendReader::new(first : &Reader, second : &Reader) -> AppendReader {
  { first, second, use_second: false }
}

///|
pub impl Reader for AppendReader with read(self) {
  if not(self.use_second) {
    let chunk = self.first.read()
    if not(chunk.is_empty()) {
      return chunk
    }
    self.use_second = true
  }
  self.second.read()
}

///|
/// Observes slices without transforming (for hashing, logging, checksums).
struct TapReader {
  inner : &Reader
  f : (BytesView) -> Unit
}

///|
pub fn TapReader::new(reader : &Reader, f : (BytesView) -> Unit) -> TapReader {
  { inner: reader, f }
}

///|
pub impl Reader for TapReader with read(self) {
  let chunk = self.inner.read()
  if not(chunk.is_empty()) {
    (self.f)(chunk)
  }
  chunk
}

///|
/// Observes slices on the writer side without transforming.
struct TapWriter {
  inner : &Writer
  f : (BytesView) -> Unit
}

///|
pub fn TapWriter::new(writer : &Writer, f : (BytesView) -> Unit) -> TapWriter {
  { inner: writer, f }
}

///|
pub impl Writer for TapWriter with write(self, data) {
  if not(data.is_empty()) {
    (self.f)(data)
  }
  self.inner.write(data)
}

///|
/// Tracks byte position on reads.
struct CountedReader {
  inner : &Reader
  mut pos : Int
}

///|
pub fn CountedReader::new(reader : &Reader) -> CountedReader {
  { inner: reader, pos: 0 }
}

///|
pub fn CountedReader::position(self : CountedReader) -> Int {
  self.pos
}

///|
pub impl Reader for CountedReader with read(self) {
  let chunk = self.inner.read()
  self.pos += chunk.length()
  chunk
}

///|
/// Tracks byte position on writes.
struct CountedWriter {
  inner : &Writer
  mut pos : Int
}

///|
pub fn CountedWriter::new(writer : &Writer) -> CountedWriter {
  { inner: writer, pos: 0 }
}

///|
pub fn CountedWriter::position(self : CountedWriter) -> Int {
  self.pos
}

///|
pub impl Writer for CountedWriter with write(self, data) {
  self.pos += data.length()
  self.inner.write(data)
}
