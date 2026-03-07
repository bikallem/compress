///|
test "bench crc32 1kb" (b : @bench.T) {
  let data = gen_text(1024)
  b.bench(name="crc32_1kb", fn() { b.keep(@checksum.crc32(data[:])) })
}

///|
test "bench crc32 10kb" (b : @bench.T) {
  let data = gen_text(10240)
  b.bench(name="crc32_10kb", fn() { b.keep(@checksum.crc32(data[:])) })
}

///|
test "bench crc32 100kb" (b : @bench.T) {
  let data = gen_text(102400)
  b.bench(name="crc32_100kb", fn() { b.keep(@checksum.crc32(data[:])) })
}

///|
test "bench adler32 1kb" (b : @bench.T) {
  let data = gen_text(1024)
  b.bench(name="adler32_1kb", fn() { b.keep(@checksum.adler32(data[:])) })
}

///|
test "bench adler32 10kb" (b : @bench.T) {
  let data = gen_text(10240)
  b.bench(name="adler32_10kb", fn() { b.keep(@checksum.adler32(data[:])) })
}

///|
test "bench adler32 100kb" (b : @bench.T) {
  let data = gen_text(102400)
  b.bench(name="adler32_100kb", fn() { b.keep(@checksum.adler32(data[:])) })
}
