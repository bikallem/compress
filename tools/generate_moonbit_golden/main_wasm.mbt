///|
fn main {
  let _ : @bzip2.Deflater? = None
  let _ : @flate.Deflater? = None
  let _ : @gzip.Deflater? = None
  let _ : @lzw.BitOrder? = None
  let _ : @zlib.Deflater? = None
  let _ = @buffer.new()
  let _ = @env.args()
  println("This tool requires --target native")
}
