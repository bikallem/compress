///|
/// Streams 50MB through FnReader -> TapReader -> CountedReader -> FnWriter.
/// No data accumulation — bounded memory usage.
/// Run under valgrind to verify flat heap profile.
#cfg(target="native")
fn main {
  run() catch {
    e => println("Error: \{e}")
  }
}

///|
#cfg(target="native")
fn run() -> Unit raise {
  let total_bytes = 50 * 1024 * 1024 // 50MB
  let chunk_size = 4096
  let mut generated = 0
  let reader = @stream.FnReader::new(slice_length=chunk_size, fn(buf) {
    if generated >= total_bytes {
      return 0
    }
    let remaining = total_bytes - generated
    let n = if remaining < buf.length() { remaining } else { buf.length() }
    for i in 0..<n {
      buf[i] = ((generated + i) % 251).to_byte()
    }
    generated += n
    n
  })
  let mut checksum : UInt = 0U
  let tapped = @stream.TapReader::new(reader, fn(chunk) {
    for i in 0..<chunk.length() {
      checksum = (checksum << 5) | (checksum >> 27)
      checksum = checksum ^ chunk[i].to_int().reinterpret_as_uint()
    }
  })
  let counted = @stream.CountedReader::new(tapped)
  let writer = @stream.FnWriter::new(fn(_data) {  })
  @stream.pipe(counted, writer)
  println("Streamed \{counted.position()} bytes, checksum=\{checksum}")
}

///|
#cfg(target="wasm-gc")
fn main {
  println("This tool requires --target native")
}
