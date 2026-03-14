///|
pub fn read_uint32_le(data : Bytes, offset : Int) -> UInt {
  data[offset].to_uint() |
  (data[offset + 1].to_uint() << 8) |
  (data[offset + 2].to_uint() << 16) |
  (data[offset + 3].to_uint() << 24)
}

///|
pub fn read_uint32_be(data : Bytes, offset : Int) -> UInt {
  (data[offset].to_uint() << 24) |
  (data[offset + 1].to_uint() << 16) |
  (data[offset + 2].to_uint() << 8) |
  data[offset + 3].to_uint()
}

///|
pub fn write_uint32_le(buf : @buffer.Buffer, v : UInt) -> Unit {
  buf.write_byte((v & 0xFFU).to_byte())
  buf.write_byte(((v >> 8) & 0xFFU).to_byte())
  buf.write_byte(((v >> 16) & 0xFFU).to_byte())
  buf.write_byte(((v >> 24) & 0xFFU).to_byte())
}

///|
pub fn write_uint32_be(buf : @buffer.Buffer, v : UInt) -> Unit {
  buf.write_byte(((v >> 24) & 0xFFU).to_byte())
  buf.write_byte(((v >> 16) & 0xFFU).to_byte())
  buf.write_byte(((v >> 8) & 0xFFU).to_byte())
  buf.write_byte((v & 0xFFU).to_byte())
}
