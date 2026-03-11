///|
fn main {
  // Reference imported packages to suppress unused-package warnings.
  // This file is only compiled on wasm/wasm-gc/js targets.
  let _ : @checksum.CRC32? = None
  let _ : @lzw.BitOrder? = None
  let _ : @moonasync.Task[Unit]? = None
  ignore(@fs.unimplemented)
  let _ = @env.args()
  let _ : @strconv.StrConvError? = None
  println("This tool requires --target native")
}
