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
fn check_large_fixture() -> String? {
  let compressed = read_file("testdata/woff2_dejavu_tables.br")
  if compressed.length() == 0 {
    return Some("could not read compressed file")
  }
  let result = @brotli.decompress(compressed) catch {
    e => return Some("decompress error: \{e}")
  }
  let expected = read_file("testdata/woff2_dejavu_tables.bin")
  if expected.length() == 0 {
    return Some("could not read expected file")
  }
  if result.length() != expected.length() {
    return Some(
      "length mismatch: got \{result.length()}, expected \{expected.length()}",
    )
  }
  for i in 0..<result.length() {
    if result[i] != expected[i] {
      return Some(
        "first mismatch at byte \{i}: got 0x\{result[i].to_int().to_string(radix=16)}, expected 0x\{expected[i].to_int().to_string(radix=16)}",
      )
    }
  }
  None
}

///|
test "brotli decompress large WOFF2 table data" {
  match check_large_fixture() {
    Some(msg) => fail(msg)
    None => ()
  }
}

///|
fn main {
  match check_large_fixture() {
    Some(msg) => println("FAIL: \{msg}")
    None => println("PASS: large fixture matches expected output")
  }
}
