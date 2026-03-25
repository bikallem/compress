///|
fn main {
  @brotli.compress(b"") |> ignore
  println("tools/test_brotli_large is native-only")
}
