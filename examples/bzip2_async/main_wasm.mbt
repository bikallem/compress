///|
fn main {
  // Reference imported packages to suppress unused-package warnings.
  // This file is only compiled on wasm/wasm-gc/js targets.
  let _ : @bz2.Deflater? = None
  let _ : @moonasync.Task[Unit]? = None
  println("This example requires --target native")
}
