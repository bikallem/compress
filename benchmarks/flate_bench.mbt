///|
test "bench flate compress default text_1kb" (b : @bench.T) {
  let data = gen_text(1024)
  b.bench(name="flate_compress_default_1kb", fn() {
    b.keep(try! @flate.compress(data))
  })
}

///|
test "bench flate compress default text_10kb" (b : @bench.T) {
  let data = gen_text(10240)
  b.bench(name="flate_compress_default_10kb", fn() {
    b.keep(try! @flate.compress(data))
  })
}

///|
test "bench flate compress best_speed text_10kb" (b : @bench.T) {
  let data = gen_text(10240)
  b.bench(name="flate_compress_speed_10kb", fn() {
    b.keep(try! @flate.compress(data, level=BestSpeed))
  })
}

///|
test "bench flate compress best_compression text_10kb" (b : @bench.T) {
  let data = gen_text(10240)
  b.bench(name="flate_compress_best_10kb", fn() {
    b.keep(try! @flate.compress(data, level=BestCompression))
  })
}

///|
test "bench flate decompress text_10kb" (b : @bench.T) {
  let data = gen_text(10240)
  let compressed = @flate.compress(data)
  b.bench(name="flate_decompress_10kb", fn() {
    b.keep(try! @flate.decompress(compressed))
  })
}

///|
test "bench flate compress zeros_10kb" (b : @bench.T) {
  let data = gen_zeros(10240)
  b.bench(name="flate_compress_zeros_10kb", fn() {
    b.keep(try! @flate.compress(data))
  })
}

///|
test "bench flate compress random_10kb" (b : @bench.T) {
  let data = gen_random(10240)
  b.bench(name="flate_compress_random_10kb", fn() {
    b.keep(try! @flate.compress(data, level=BestSpeed))
  })
}

///|
test "bench flate compress best_speed text_1kb" (b : @bench.T) {
  let data = gen_text(1024)
  b.bench(name="flate_compress_speed_1kb", fn() {
    b.keep(try! @flate.compress(data, level=BestSpeed))
  })
}

///|
test "bench flate decompress text_1kb" (b : @bench.T) {
  let data = gen_text(1024)
  let compressed = @flate.compress(data)
  b.bench(name="flate_decompress_1kb", fn() {
    b.keep(try! @flate.decompress(compressed))
  })
}

///|
test "bench flate decompress zeros_10kb" (b : @bench.T) {
  let data = gen_zeros(10240)
  let compressed = @flate.compress(data)
  b.bench(name="flate_decompress_zeros_10kb", fn() {
    b.keep(try! @flate.decompress(compressed))
  })
}

///|
test "bench flate decompress text_100kb" (b : @bench.T) {
  let data = gen_text(102400)
  let compressed = @flate.compress(data)
  b.bench(name="flate_decompress_100kb", fn() {
    b.keep(try! @flate.decompress(compressed))
  })
}

///|
test "bench flate decompress text_1mb" (b : @bench.T) {
  let data = gen_text(1048576)
  let compressed = @flate.compress(data)
  b.bench(name="flate_decompress_1mb", fn() {
    b.keep(try! @flate.decompress(compressed))
  })
}

///|
test "bench flate decompress text_10mb" (b : @bench.T) {
  let data = gen_text(10485760)
  let compressed = @flate.compress(data)
  b.bench(name="flate_decompress_10mb", fn() {
    b.keep(try! @flate.decompress(compressed))
  })
}

///|
test "bench flate decompress text_100mb" (b : @bench.T) {
  let data = gen_text(104857600)
  let compressed = @flate.compress(data)
  b.bench(name="flate_decompress_100mb", fn() {
    b.keep(try! @flate.decompress(compressed))
  })
}

///|
test "bench flate compress default text_100kb" (b : @bench.T) {
  let data = gen_text(102400)
  b.bench(name="flate_compress_default_100kb", fn() {
    b.keep(try! @flate.compress(data))
  })
}

///|
test "bench flate compress default text_1mb" (b : @bench.T) {
  let data = gen_text(1048576)
  b.bench(name="flate_compress_default_1mb", fn() {
    b.keep(try! @flate.compress(data))
  })
}

///|
test "bench flate compress default text_10mb" (b : @bench.T) {
  let data = gen_text(10485760)
  b.bench(name="flate_compress_default_10mb", fn() {
    b.keep(try! @flate.compress(data))
  })
}

///|
test "bench flate compress default text_100mb" (b : @bench.T) {
  let data = gen_text(104857600)
  b.bench(name="flate_compress_default_100mb", fn() {
    b.keep(try! @flate.compress(data))
  })
}

///|
test "bench flate compress dict text_10kb" (b : @bench.T) {
  let dict : Bytes = b"The quick brown fox jumps over the lazy dog. "
  let data = gen_text(10240)
  b.bench(name="flate_compress_dict_10kb", fn() {
    let d = @flate.Deflater::new(dict~)
    let buf = @buffer.new()
    match d.encode(Some(data)) {
      Data(out) => buf.write_bytes(out)
      _ => ()
    }
    loop d.encode(None) {
      Data(out) => {
        buf.write_bytes(out)
        continue d.encode(None)
      }
      _ => break
    }
    b.keep(buf.to_bytes())
  })
}

///|
test "bench flate compress dict text_100kb" (b : @bench.T) {
  let dict : Bytes = b"The quick brown fox jumps over the lazy dog. "
  let data = gen_text(102400)
  b.bench(name="flate_compress_dict_100kb", fn() {
    let d = @flate.Deflater::new(dict~)
    let buf = @buffer.new()
    match d.encode(Some(data)) {
      Data(out) => buf.write_bytes(out)
      _ => ()
    }
    loop d.encode(None) {
      Data(out) => {
        buf.write_bytes(out)
        continue d.encode(None)
      }
      _ => break
    }
    b.keep(buf.to_bytes())
  })
}
