///|
fn main {
  // Reference imported packages to suppress unused-package warnings.
  // This file is only compiled on wasm/wasm-gc/js targets.
  let _ : @zliblib.Deflater? = None
  let _ : @moonasync.Task[Unit]? = None
  let _ : @io.PipeRead? = None
  let _ : @blit.Buffer? = None
  println("This example requires --target native")
}
