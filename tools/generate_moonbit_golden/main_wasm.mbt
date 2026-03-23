///|
fn main {
  let _ : @bzip2.Deflater? = None
  let _ : @flate.Deflater? = None
  let _ : @gzip.Deflater? = None
  let _ : @lzw.BitOrder? = None
  let _ : @zlib.Deflater? = None
  let _ : @brotli.Inflater? = None
  let _ : @lz4.Inflater? = None
  let _ : @snappy.SnappyError? = None
  let _ : @zstd.Inflater? = None
  let _ = @blit.Buffer::new()
  let _ = @env.args()
  println("This tool requires --target native")
}
