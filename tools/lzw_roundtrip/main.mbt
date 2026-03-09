///|
let help_message : String =
  #|Usage: lzw_roundtrip COMMAND [ARGS...]
  #|
  #|Commands:
  #|  compress-file INPUT OUTPUT [ORDER] [LIT_WIDTH]
  #|  decompress-file INPUT OUTPUT [ORDER] [LIT_WIDTH]
  #|  fingerprint-file INPUT
  #|
  #|Notes:
  #|  - This tool exists for the manual native 50GB acceptance harness.
  #|  - File IO is buffered at the boundary so the codec can remain
  #|    `Reader`/`Writer`-driven without whole-stream buffering.

///|
#warnings("-alert_internal")
struct BufferedInputReader[R] {
  inner : R
  read_buf : @io.ReaderBuffer
  buf : FixedArray[Byte]
  mut start : Int
  mut len : Int
}

///|
#warnings("-alert_internal")
fn[R] BufferedInputReader::new(
  inner : R,
  size? : Int = 64 * 1024,
) -> BufferedInputReader[R] {
  {
    inner,
    read_buf: @io.ReaderBuffer::new(),
    buf: FixedArray::make(size, b'\x00'),
    start: 0,
    len: 0,
  }
}

///|
pub impl[R : @io.Reader] @io.Reader for BufferedInputReader[R] with _get_internal_buffer(
  self,
) {
  self.read_buf
}

///|
pub impl[R : @io.Reader] @io.Reader for BufferedInputReader[R] with _direct_read(
  self,
  dst,
  offset~,
  max_len~,
) {
  if self.len == 0 {
    self.len = self.inner.read(self.buf, offset=0, max_len=self.buf.length())
    self.start = 0
  }
  if self.len == 0 {
    return 0
  }
  let n = if max_len < self.len { max_len } else { self.len }
  dst.unsafe_blit(offset, self.buf, self.start, n)
  self.start += n
  self.len -= n
  n
}

///|
#cfg(target="native")
fn main {
  @moonasync.run_async_main(async fn() {
    run() catch {
      e => fail("lzw_roundtrip: \{e}")
    }
  })
}

///|
#cfg(target="wasm-gc")
fn main {
  println("This tool requires --target native")
}

///|
fn parse_order(order : String) -> @lzw.BitOrder raise {
  match order {
    "lsb" | "LSB" | "gif" | "GIF" => @lzw.LSB
    "msb" | "MSB" | "tiff" | "TIFF" | "pdf" | "PDF" => @lzw.MSB
    _ => fail("invalid bit order: \{order}")
  }
}

///|
fn parse_lit_width(text : String) -> Int raise {
  @strconv.parse_int(text)
}

///|
async fn compress_file(
  input_path : String,
  output_path : String,
  order : @lzw.BitOrder,
  lit_width : Int,
) -> Unit {
  let raw_input = @fs.open(input_path, mode=ReadOnly)
  let raw_output = @fs.open(
    output_path,
    mode=WriteOnly,
    create=0o644,
    truncate=true,
  )
  let input = BufferedInputReader::new(raw_input)
  let output = @io.BufferedWriter::new(raw_output, size=64 * 1024)
  defer raw_input.close()
  defer raw_output.close()
  @lzw.compress(input, output, order, lit_width)
  output.flush()
}

///|
async fn decompress_file(
  input_path : String,
  output_path : String,
  order : @lzw.BitOrder,
  lit_width : Int,
) -> Unit {
  let raw_input = @fs.open(input_path, mode=ReadOnly)
  let raw_output = @fs.open(
    output_path,
    mode=WriteOnly,
    create=0o644,
    truncate=true,
  )
  let input = BufferedInputReader::new(raw_input)
  let output = @io.BufferedWriter::new(raw_output, size=64 * 1024)
  defer raw_input.close()
  defer raw_output.close()
  @lzw.decompress(input, output, order, lit_width)
  output.flush()
}

///|
async fn fingerprint_file(path : String) -> Unit {
  let file = @fs.open(path, mode=ReadOnly)
  defer file.close()
  let size = file.size()
  let crc = @checksum.CRC32::new()
  while file.read_some(max_len=1024 * 1024) is Some(chunk) {
    crc.update(chunk[:])
  }
  println("\{size}\t\{crc.checksum()}")
}

///|
async fn run() -> Unit {
  match @env.args()[1:] {
    [] | ["-h"] | ["--help"] | ["help"] => println(help_message)
    ["compress-file", input, output] =>
      compress_file(input, output, @lzw.LSB, 8)
    ["compress-file", input, output, order, lit_width] =>
      compress_file(
        input,
        output,
        parse_order(order),
        parse_lit_width(lit_width),
      )
    ["decompress-file", input, output] =>
      decompress_file(input, output, @lzw.LSB, 8)
    ["decompress-file", input, output, order, lit_width] =>
      decompress_file(
        input,
        output,
        parse_order(order),
        parse_lit_width(lit_width),
      )
    ["fingerprint-file", input] => fingerprint_file(input)
    _ => fail(help_message)
  }
}
