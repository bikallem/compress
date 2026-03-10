///|
const IO_BUFFER_SIZE : Int = 64 * 1024

///|
const ENCODER_OUTPUT_BUFFER_SIZE : Int = 2 * IO_BUFFER_SIZE

///|
fn validate_lit_width(lit_width : Int) -> Unit raise LzwError {
  guard lit_width >= 2 && lit_width <= 8 else {
    raise LzwError::InvalidLitWidth(lit_width)
  }
}

///|
priv struct InputByteBuffer {
  buf : FixedArray[Byte]
  mut start : Int
  mut len : Int
}

///|
fn InputByteBuffer::new(size? : Int = IO_BUFFER_SIZE) -> InputByteBuffer {
  { buf: FixedArray::make(size, b'\x00'), start: 0, len: 0 }
}

///|
async fn InputByteBuffer::read_byte(
  self : InputByteBuffer,
  src : &@io.Reader,
) -> Byte? raise LzwError {
  if self.start >= self.len {
    self.len = src.read(self.buf, offset=0, max_len=self.buf.length()) catch {
      e => raise LzwError::Io(e.to_string())
    }
    self.start = 0
    if self.len == 0 {
      return None
    }
  }
  let byte = self.buf[self.start]
  self.start += 1
  Some(byte)
}

///|
priv struct OutputByteBuffer {
  buf : FixedArray[Byte]
  mut len : Int
}

///|
fn OutputByteBuffer::new(size? : Int = IO_BUFFER_SIZE) -> OutputByteBuffer {
  { buf: FixedArray::make(size, b'\x00'), len: 0 }
}

///|
async fn OutputByteBuffer::flush(
  self : OutputByteBuffer,
  dst : &@io.Writer,
) -> Unit raise LzwError {
  if self.len == 0 {
    return
  }
  dst.write(self.buf.unsafe_reinterpret_as_bytes()[:self.len]) catch {
    e => raise LzwError::Io(e.to_string())
  }
  self.len = 0
}

///|
fn OutputByteBuffer::write_byte_sync(
  self : OutputByteBuffer,
  byte : Byte,
) -> Unit {
  guard self.len < self.buf.length() else {
    abort("lzw encoder output buffer overflow")
  }
  self.buf[self.len] = byte
  self.len += 1
}

///|
async fn OutputByteBuffer::write_byte(
  self : OutputByteBuffer,
  dst : &@io.Writer,
  byte : Byte,
) -> Unit raise LzwError {
  if self.len >= self.buf.length() {
    self.flush(dst)
  }
  self.write_byte_sync(byte)
}

///|
async fn OutputByteBuffer::write_fixed(
  self : OutputByteBuffer,
  dst : &@io.Writer,
  src : FixedArray[Byte],
  start : Int,
  len : Int,
) -> Unit raise LzwError {
  let mut src_start = start
  let mut remaining = len
  while remaining > 0 {
    if self.len >= self.buf.length() {
      self.flush(dst)
    }
    let available = self.buf.length() - self.len
    let n = if remaining < available { remaining } else { available }
    @blit.blit_fixed_array(self.buf, self.len, src, src_start, n)
    self.len += n
    src_start += n
    remaining -= n
  }
}
