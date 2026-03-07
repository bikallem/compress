///|
test "bench crc32 10kb" (b : @bench.T) {
  let data = gen_text(10240)
  b.bench(name="crc32_10kb", fn() { b.keep(@checksum.crc32(data[:])) })
}

///|
test "bench adler32 10kb" (b : @bench.T) {
  let data = gen_text(10240)
  b.bench(name="adler32_10kb", fn() { b.keep(@checksum.adler32(data[:])) })
}
