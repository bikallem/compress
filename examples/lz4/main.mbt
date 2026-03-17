///|
fn run() -> Unit raise {
  // One-shot compress/decompress (LZ4 frame format)
  let original = b"Hello, LZ4 compression!"
  let compressed = @lz4_codec.compress(original)
  let decompressed = @lz4_codec.decompress(compressed)
  assert_eq(decompressed, original)
  println(
    "LZ4: \{original.length()} -> \{compressed.length()} bytes, round-trip OK",
  )

  // Streaming API
  let d = @lz4_codec.Deflater::new()
  let data = b"Streaming LZ4 data for compression"
  match d.encode(Some(data[:])) {
    Ok | Data(_) | End | Error(_) => ()
  }
  let cbuf = @buffer.new()
  loop d.encode(None) {
    Data(out) => {
      cbuf.write_bytes(out)
      continue d.encode(None)
    }
    End | Ok | Error(_) => break
  }
  let rt_compressed = cbuf.to_bytes()
  let inf = @lz4_codec.Inflater::new()
  inf.src(rt_compressed[:])
  let dbuf = @buffer.new()
  loop inf.decode() {
    Await => break
    Data(out) => {
      dbuf.write_bytes(out)
      continue inf.decode()
    }
    End => break
    Error(_) => break
  }
  assert_eq(dbuf.to_bytes(), data)
  println("Round-trip streaming: OK (\{rt_compressed.length()} bytes)")
}

///|
fn main {
  run() catch {
    e => println("Error: \{e}")
  }
}
