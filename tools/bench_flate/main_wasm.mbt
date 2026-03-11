///|
fn main {
  // Reference imported packages to suppress unused-package warnings.
  // This file is only compiled on wasm/wasm-gc/js targets.
  let _ : @flate.Deflater? = None
  let _ = @env.args()
  println("This tool requires --target native")
}
