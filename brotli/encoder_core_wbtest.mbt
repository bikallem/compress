///|
test "brotli fixed literal tree decodes every byte" {
  let writer = BitWriter::new()
  write_fixed_literal_tree(writer) catch {
    e => abort(e.to_string())
  }
  for i in 0..<256 {
    write_fixed_literal(writer, i.to_byte())
  }
  let reader = BitReader::new()
  reader.set_input(writer.finish()[:])
  let decoder = read_prefix_code(reader, 256) catch {
    e => abort(e.to_string())
  }
  for i in 0..<256 {
    let symbol = match decoder.decode(reader) {
      Some(value) => value
      None => abort("missing literal")
    }
    assert_eq(symbol, i)
  }
}

///|
test "brotli compressed literal-only encoder round-trips" {
  let pattern = b"abcdef0123456789"
  let data = Bytes::makei(pattern.length() * 64, fn(i) {
    pattern[i % pattern.length()]
  })
  let compressed = compress_literal_only(data) catch {
    e => abort(e.to_string())
  }
  let decompressed = decompress(compressed) catch { e => abort(e.to_string()) }
  assert_eq(decompressed, data)
}

///|
test "brotli compressed literal-only encoder handles large input" {
  let data = Bytes::makei(100000, fn(i) { (i % 251).to_byte() })
  let compressed = compress_literal_only(data) catch {
    e => abort(e.to_string())
  }
  let decompressed = decompress(compressed) catch { e => abort(e.to_string()) }
  assert_eq(decompressed, data)
}

///|
test "brotli default compression uses compressed metablocks" {
  let data = b"brotli literal-only compressed metablock"
  let compressed = compress(data) catch { e => abort(e.to_string()) }
  let uncompressed = trivial_compress(data) catch { e => abort(e.to_string()) }
  assert_eq(decompress(compressed) catch { e => abort(e.to_string()) }, data)
  assert_eq(
    compress(data, level=NoCompression) catch {
      e => abort(e.to_string())
    },
    uncompressed,
  )
  assert_true(compressed != uncompressed)
}

///|
test "brotli higher quality compresses long runs better" {
  let data = Bytes::makei(8192, fn(_i) { b'Z' })
  let fast = compress(data, level=BestSpeed) catch { e => abort(e.to_string()) }
  let best = compress(data, level=BestCompression) catch {
    e => abort(e.to_string())
  }
  assert_eq(decompress(fast) catch { e => abort(e.to_string()) }, data)
  assert_eq(decompress(best) catch { e => abort(e.to_string()) }, data)
  assert_true(best.length() < fast.length())
}
