///|
test "blit_fixed_array copies bytes correctly" {
  let src : FixedArray[Byte] = [b'a', b'b', b'c', b'd', b'e']
  let dst : FixedArray[Byte] = FixedArray::make(5, b'\x00')
  @blit.blit_fixed_array(dst, 0, src, 0, 5)
  inspect(dst, content="[b'\\x61', b'\\x62', b'\\x63', b'\\x64', b'\\x65']")
}

///|
test "blit_fixed_array with offsets" {
  let src : FixedArray[Byte] = [b'a', b'b', b'c', b'd', b'e']
  let dst : FixedArray[Byte] = FixedArray::make(5, b'\x00')
  @blit.blit_fixed_array(dst, 1, src, 2, 3)
  inspect(
    dst,
    content="[b'\\x00', b'\\x63', b'\\x64', b'\\x65', b'\\x00']",
  )
}

///|
test "blit_fixed_array zero length is no-op" {
  let src : FixedArray[Byte] = [b'a', b'b']
  let dst : FixedArray[Byte] = FixedArray::make(2, b'\x00')
  @blit.blit_fixed_array(dst, 0, src, 0, 0)
  inspect(dst, content="[b'\\x00', b'\\x00']")
}

///|
test "blit_fixed_array overlapping forward (same array)" {
  let buf : FixedArray[Byte] = [b'a', b'b', b'c', b'd', b'e']
  @blit.blit_fixed_array(buf, 1, buf, 0, 3)
  inspect(buf, content="[b'\\x61', b'\\x61', b'\\x62', b'\\x63', b'\\x65']")
}

///|
test "blit_fixed_array overlapping backward (same array)" {
  let buf : FixedArray[Byte] = [b'a', b'b', b'c', b'd', b'e']
  @blit.blit_fixed_array(buf, 0, buf, 2, 3)
  inspect(buf, content="[b'\\x63', b'\\x64', b'\\x65', b'\\x64', b'\\x65']")
}

///|
test "fill_bytes fills region with value" {
  let dst : FixedArray[Byte] = FixedArray::make(6, b'\x00')
  @blit.fill_bytes(dst, 1, 0xFF, 4)
  inspect(
    dst,
    content="[b'\\x00', b'\\xFF', b'\\xFF', b'\\xFF', b'\\xFF', b'\\x00']",
  )
}

///|
test "fill_bytes zero length is no-op" {
  let dst : FixedArray[Byte] = FixedArray::make(3, b'\x00')
  @blit.fill_bytes(dst, 0, 0xAB, 0)
  inspect(dst, content="[b'\\x00', b'\\x00', b'\\x00']")
}

///|
test "make_uninit returns array of correct length" {
  let arr = @blit.make_uninit(10)
  assert_eq(arr.length(), 10)
}

///|
test "make_uninit zero length" {
  let arr = @blit.make_uninit(0)
  assert_eq(arr.length(), 0)
}
