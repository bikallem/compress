///|
test "deflate hash uses unsigned little-endian words" {
  let data : Bytes = b"\xff\x80\xaa\xcc\x11"
  let window = FixedArray::makei(data.length(), fn(i) { data[i] })
  let raw = data[0].to_uint() |
    (data[1].to_uint() << 8) |
    (data[2].to_uint() << 16) |
    (data[3].to_uint() << 24)
  let expected = ((raw * 0x1e35a7bdU).reinterpret_as_int() >> 17) &
    ((1 << 15) - 1)
  assert_eq(deflate_u32_le(window, 0), raw)
  let d : Deflater = {
    level: 6,
    w: BitWriter::new(),
    phase: Ready,
    window: FixedArray::make(2 * WINDOW_SIZE, b'\x00'),
    window_end: 0,
    index: 0,
    head: FixedArray::make(1 << 15, -1),
    prev: FixedArray::make(WINDOW_SIZE, -1),
    base: 0,
    tokens: [],
    prev_match_len: 0,
    prev_match_dist: 0,
    prev_literal: b'\x00',
    has_prev: false,
  }
  for i in 0..<data.length() {
    d.window.unsafe_set(i, data[i])
  }
  assert_eq(d.hash4(0, (1 << 15) - 1), expected)
}
