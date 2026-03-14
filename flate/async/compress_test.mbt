///|
async test "round-trip compress then decompress" {
  let input = Bytes::makei(1024, fn(i) { (i % 256).to_byte() })
  let (comp_read, comp_write) = @io.pipe()
  let (decomp_read, decomp_write) = @io.pipe()
  let (in_read, in_write) = @io.pipe()
  @runtime.with_task_group(async fn(g) {
    g.spawn_bg(async fn() {
      in_write.write(input)
      in_write.close()
    })
    g.spawn_bg(async fn() {
      @async.compress(in_read, comp_write)
      comp_write.close()
    })
    g.spawn_bg(async fn() {
      @async.decompress(comp_read, decomp_write)
      decomp_write.close()
    })
    let output = decomp_read.read_all()
    let output_bytes = output.binary()
    assert_eq(output_bytes.length(), input.length())
    for i in 0..<input.length() {
      assert_eq(output_bytes[i], input[i])
    }
  })
}
