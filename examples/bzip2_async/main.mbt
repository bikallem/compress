///|
fn main {
  @moonasync.run_async_main(async fn() {
    let original = b"Hello, bzip2 async streaming!"
    let compressed = @bz2.compress(original)

    @moonasync.with_task_group(root => {
      root.spawn_bg(() => {
        let restored = @bz2.decompress(compressed)
        assert_eq(restored, original)
        println(
          "Async bzip2 decompress: round-trip OK (\{restored.length()} bytes)",
        )
      })
    })

    // Round-trip via one-shot API in async context
    let rt_compressed = @bz2.compress(original)
    let rt_result = @bz2.decompress(rt_compressed)
    assert_eq(rt_result, original)
    println("Async round-trip: OK (\{rt_result.length()} bytes)")
  })
}
