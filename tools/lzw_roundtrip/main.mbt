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
  #|  - Streaming compress/decompress with constant memory usage.

///|
/// Adapter: wraps @fs.File as @lzwio.Reader for streaming decompression.
struct FileReader {
  file : @fs.File
  mut buf : Bytes
  mut pos : Int
}

///|
fn FileReader::new(file : @fs.File) -> FileReader {
  { file, buf: b"", pos: 0 }
}

///|
impl @lzwio.Reader for FileReader with read(self) -> BytesView {
  // If we have buffered data, return it
  if self.pos < self.buf.length() {
    let view = self.buf[self.pos:]
    self.pos = self.buf.length()
    return view
  }
  // Read more from file
  let data = self.file.read_some(max_len=65536) catch {
    e => raise @lzwio.Io(e.to_string())
  }
  match data {
    Some(data) => {
      self.buf = data
      self.pos = data.length()
      data[:]
    }
    None => b""
  }
}

///|
impl @lzwio.Reader for FileReader with read_byte(self) -> Byte {
  if self.pos < self.buf.length() {
    let b = self.buf[self.pos]
    self.pos += 1
    return b
  }
  // Refill buffer
  let data = self.file.read_some(max_len=65536) catch {
    e => raise @lzwio.Io(e.to_string())
  }
  match data {
    Some(data) => {
      self.buf = data
      self.pos = 1
      data[0]
    }
    None => raise @lzwio.UnexpectedEod
  }
}

///|
/// Adapter: wraps @fs.File as @lzwio.Writer for streaming compression.
struct FileWriter {
  file : @fs.File
}

///|
fn FileWriter::new(file : @fs.File) -> FileWriter {
  { file, }
}

///|
impl @lzwio.Writer for FileWriter with write(self, data) {
  if data.is_empty() {
    return
  }
  self.file.write(data.to_bytes()) catch {
    e => raise @lzwio.Io(e.to_string())
  }
}

///|
impl @lzwio.Writer for FileWriter with write_byte(self, b) {
  self.file.write(Bytes::make(1, b)) catch {
    e => raise @lzwio.Io(e.to_string())
  }
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
  let input_file = @fs.open(input_path, mode=ReadOnly)
  defer input_file.close()
  let output_file = @fs.open(
    output_path,
    mode=WriteOnly,
    create=0o644,
    truncate=true,
  )
  defer output_file.close()
  let src = FileReader::new(input_file)
  let dst = FileWriter::new(output_file)
  @lzw.compress(src, dst, order, lit_width~)
}

///|
async fn decompress_file(
  input_path : String,
  output_path : String,
  order : @lzw.BitOrder,
  lit_width : Int,
) -> Unit {
  let input_file = @fs.open(input_path, mode=ReadOnly)
  defer input_file.close()
  let output_file = @fs.open(
    output_path,
    mode=WriteOnly,
    create=0o644,
    truncate=true,
  )
  defer output_file.close()
  let src = FileReader::new(input_file)
  let dst = FileWriter::new(output_file)
  @lzw.decompress(src, dst, order, lit_width~)
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
