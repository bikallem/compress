///|
#cfg(target="native")
#warnings("-deprecated")
fn run_bytes(task : async () -> Bytes) -> Bytes raise {
  let mut result : Result[Bytes, Error]? = None
  @moonasync.with_event_loop(_ => result = Some(try? task())) catch {
    e => result = Some(Err(e))
  }
  match result {
    Some(Ok(bytes)) => bytes
    Some(Err(err)) => raise err
    None => abort("unreachable")
  }
}

///|
#cfg(target="native")
fn bench_compress(data : Bytes) -> Bytes raise {
  run_bytes(async fn() { @lzw.compress_bytes(data, @lzw.LSB, 8) })
}

///|
#cfg(target="native")
fn bench_decompress(data : Bytes) -> Bytes raise {
  run_bytes(async fn() { @lzw.decompress_bytes(data, @lzw.LSB, 8) })
}

///|
#cfg(target="native")
test "bench lzw compress LSB text_1kb" (b : @bench.T) {
  let data = gen_text(1024)
  b.bench(name="lzw_compress_lsb_1kb", fn() {
    b.keep(try! bench_compress(data))
  })
}

///|
#cfg(target="native")
test "bench lzw compress LSB text_10kb" (b : @bench.T) {
  let data = gen_text(10240)
  b.bench(name="lzw_compress_lsb_10kb", fn() {
    b.keep(try! bench_compress(data))
  })
}

///|
#cfg(target="native")
test "bench lzw decompress LSB text_1kb" (b : @bench.T) {
  let data = gen_text(1024)
  let compressed = bench_compress(data)
  b.bench(name="lzw_decompress_lsb_1kb", fn() {
    b.keep(try! bench_decompress(compressed))
  })
}

///|
#cfg(target="native")
test "bench lzw decompress LSB text_10kb" (b : @bench.T) {
  let data = gen_text(10240)
  let compressed = bench_compress(data)
  b.bench(name="lzw_decompress_lsb_10kb", fn() {
    b.keep(try! bench_decompress(compressed))
  })
}

///|
#cfg(target="native")
test "bench lzw decompress LSB text_100kb" (b : @bench.T) {
  let data = gen_text(102400)
  let compressed = bench_compress(data)
  b.bench(name="lzw_decompress_lsb_100kb", fn() {
    b.keep(try! bench_decompress(compressed))
  })
}

///|
#cfg(target="native")
test "bench lzw decompress LSB text_1mb" (b : @bench.T) {
  let data = gen_text(1048576)
  let compressed = bench_compress(data)
  b.bench(name="lzw_decompress_lsb_1mb", fn() {
    b.keep(try! bench_decompress(compressed))
  })
}

///|
#cfg(target="native")
test "bench lzw decompress LSB text_10mb" (b : @bench.T) {
  let data = gen_text(10485760)
  let compressed = bench_compress(data)
  b.bench(name="lzw_decompress_lsb_10mb", fn() {
    b.keep(try! bench_decompress(compressed))
  })
}

///|
#cfg(target="native")
test "bench lzw decompress LSB text_100mb" (b : @bench.T) {
  let data = gen_text(104857600)
  let compressed = bench_compress(data)
  b.bench(name="lzw_decompress_lsb_100mb", fn() {
    b.keep(try! bench_decompress(compressed))
  })
}

///|
#cfg(target="native")
test "bench lzw compress LSB text_100kb" (b : @bench.T) {
  let data = gen_text(102400)
  b.bench(name="lzw_compress_lsb_100kb", fn() {
    b.keep(try! bench_compress(data))
  })
}

///|
#cfg(target="native")
test "bench lzw compress LSB text_1mb" (b : @bench.T) {
  let data = gen_text(1048576)
  b.bench(name="lzw_compress_lsb_1mb", fn() {
    b.keep(try! bench_compress(data))
  })
}

///|
#cfg(target="native")
test "bench lzw compress LSB text_10mb" (b : @bench.T) {
  let data = gen_text(10485760)
  b.bench(name="lzw_compress_lsb_10mb", fn() {
    b.keep(try! bench_compress(data))
  })
}

///|
#cfg(target="native")
test "bench lzw compress LSB text_100mb" (b : @bench.T) {
  let data = gen_text(104857600)
  b.bench(name="lzw_compress_lsb_100mb", fn() {
    b.keep(try! bench_compress(data))
  })
}
