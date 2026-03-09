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
  #|  - `compress-file` and `decompress-file` currently call the in-memory
  #|    bytes APIs, so the 50GB harness is expected to fail until the LZW
  #|    `@io.Reader` / `@io.Writer` redesign lands.

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
  let input = @fs.read_file(input_path).binary()
  let output = @lzw.compress(input, order, lit_width)
  @fs.write_file(output_path, output, create=0o644, truncate=true)
}

///|
async fn decompress_file(
  input_path : String,
  output_path : String,
  order : @lzw.BitOrder,
  lit_width : Int,
) -> Unit {
  let input = @fs.read_file(input_path).binary()
  let output = @lzw.decompress(input, order, lit_width)
  @fs.write_file(output_path, output, create=0o644, truncate=true)
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
