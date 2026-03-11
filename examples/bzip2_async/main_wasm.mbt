///|
fn main {
  // Reference imported packages to suppress unused-package warnings.
  let _ : @bz2.Deflater? = None
  let _ : @moonasync.Task[Unit]? = None
  println("This example requires --target native")
}
