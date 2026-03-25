///|
#borrow(path)
extern "c" fn fopen_read(path : Bytes) -> Int64 = "golden_fopen_read"

///|
#borrow(buf)
extern "c" fn fread_into(
  handle : Int64,
  buf : FixedArray[Byte],
  max_len : Int,
) -> Int = "golden_fread"

///|
extern "c" fn fclose(handle : Int64) -> Unit = "golden_fclose"

///|
extern "c" fn file_size(handle : Int64) -> Int64 = "golden_file_size"

///|
fn path_to_cstr(s : String) -> Bytes {
  Bytes::makei(s.length() + 1, fn(i) {
    if i < s.length() {
      s[i].to_int().to_byte()
    } else {
      b'\x00'
    }
  })
}

///|
fn read_file(path : String) -> Bytes {
  let h = fopen_read(path_to_cstr(path))
  if h == 0L {
    println("ERROR: cannot open \{path}")
    return Bytes::default()
  }
  let size = file_size(h).to_int()
  if size == 0 {
    fclose(h)
    return Bytes::default()
  }
  let buf = FixedArray::make(size, b'\x00')
  let n = fread_into(h, buf, size)
  fclose(h)
  Bytes::makei(n, fn(i) { buf[i] })
}

///|
fn main {
  let compressed = read_file("testdata/woff2_dejavu_tables.br")
  if compressed.length() == 0 {
    println("FAIL: could not read compressed file")
    return
  }
  println("Compressed: \{compressed.length()} bytes")
  let result = try {
    @brotli.decompress(compressed)
  } catch {
    e => {
      println("FAIL: decompress error: \{e}")
      return
    }
  }
  println("Decompressed: \{result.length()} bytes")
  let expected = read_file("testdata/woff2_dejavu_tables.bin")
  if expected.length() == 0 {
    println("FAIL: could not read expected file")
    return
  }
  if result.length() != expected.length() {
    println(
      "FAIL: length mismatch: got \{result.length()}, expected \{expected.length()}",
    )
    return
  }
  // Show first 20 bytes of both
  let mut got_hex = ""
  let mut exp_hex = ""
  for i in 0..<20 {
    got_hex = got_hex + " \{result[i].to_int().to_string(radix=16)}"
    exp_hex = exp_hex + " \{expected[i].to_int().to_string(radix=16)}"
  }
  println("Got first 20:\{got_hex}")
  println("Exp first 20:\{exp_hex}")
  let mut mismatches = 0
  for i in 0..<result.length() {
    if result[i] != expected[i] {
      if mismatches < 10 {
        println(
          "mismatch at byte \{i}: got 0x\{result[i].to_int().to_string(radix=16)}, expected 0x\{expected[i].to_int().to_string(radix=16)}",
        )
      }
      mismatches += 1
    }
  }
  if mismatches > 0 {
    println("FAIL: \{mismatches} mismatches")
  } else {
    println("PASS: all \{result.length()} bytes match")
  }
}
