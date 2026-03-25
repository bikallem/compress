///|
#borrow(path)
extern "c" fn fixture_fopen_read(path : Bytes) -> Int64 = "golden_fopen_read"

///|
#borrow(buf)
extern "c" fn fixture_fread_into(
  handle : Int64,
  buf : FixedArray[Byte],
  max_len : Int,
) -> Int = "golden_fread"

///|
extern "c" fn fixture_fclose(handle : Int64) -> Unit = "golden_fclose"

///|
extern "c" fn fixture_file_size(handle : Int64) -> Int64 = "golden_file_size"

///|
fn fixture_path_to_cstr(s : String) -> Bytes {
  Bytes::makei(s.length() + 1, fn(i) {
    if i < s.length() {
      s[i].to_int().to_byte()
    } else {
      b'\x00'
    }
  })
}

///|
fn fixture_read_file(path : String) -> Bytes {
  let h = fixture_fopen_read(fixture_path_to_cstr(path))
  if h == 0L {
    return Bytes::default()
  }
  let size = fixture_file_size(h).to_int()
  if size == 0 {
    fixture_fclose(h)
    return Bytes::default()
  }
  let buf = FixedArray::make(size, b'\x00')
  let n = fixture_fread_into(h, buf, size)
  fixture_fclose(h)
  Bytes::makei(n, fn(i) { buf[i] })
}

///|
test "brotli decompress large WOFF2 table data (306KB)" {
  let compressed = fixture_read_file("testdata/woff2_dejavu_tables.br")
  if compressed.length() == 0 {
    return // skip if fixture not available
  }
  let expected = fixture_read_file("testdata/woff2_dejavu_tables.bin")
  if expected.length() == 0 {
    return
  }
  let result = decompress(compressed)
  assert_eq(result.length(), expected.length())
  for i in 0..<result.length() {
    if result[i] != expected[i] {
      fail(
        "first mismatch at byte \{i}: got 0x\{result[i].to_int().to_string(radix=16)}, expected 0x\{expected[i].to_int().to_string(radix=16)}",
      )
    }
  }
}
