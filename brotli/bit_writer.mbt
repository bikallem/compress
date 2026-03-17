///|
/// Bit writer for Brotli encoding. Writes bits LSB-first into a growable
/// byte array, following the layout described in write_bits.h from the
/// Brotli reference encoder.
priv struct BrotliBitWriter {
  mut storage : FixedArray[Byte] // output buffer
  mut pos : Int // bit position
}

///|
fn BrotliBitWriter::new() -> BrotliBitWriter {
  let storage = FixedArray::make(256, b'\x00')
  { storage, pos: 0 }
}

///|
/// Ensure storage has room for at least `n` additional bytes beyond the
/// current byte position.
fn BrotliBitWriter::ensure_space(self : BrotliBitWriter, n : Int) -> Unit {
  let needed = (self.pos >> 3) + n + 8 // +8 for 64-bit write headroom
  if needed > self.storage.length() {
    let new_cap = if self.storage.length() * 2 > needed {
      self.storage.length() * 2
    } else {
      needed
    }
    let new_storage = FixedArray::make(new_cap, b'\x00')
    @blit.blit_fixed_array(new_storage, 0, self.storage, 0, self.storage.length())
    self.storage = new_storage
  }
}

///|
/// Write up to 56 bits into the output buffer, LSB-first.
///
/// This mirrors BrotliWriteBits from the C reference: it reads the
/// partial byte at the current position, ORs in the new bits shifted
/// by the intra-byte offset, then writes back all affected bytes.
fn BrotliBitWriter::write_bits(
  self : BrotliBitWriter,
  n_bits : Int,
  bits : UInt64,
) -> Unit {
  self.ensure_space((n_bits + 7) >> 3)
  let byte_pos = self.pos >> 3
  let bits_in_first = self.pos & 7
  // Read the partial byte already written at the current position.
  let v = self.storage[byte_pos].to_uint64() | (bits << bits_in_first)
  // Write back up to 8 bytes (64 bits) covering all affected positions.
  // The maximum reach is ceil((n_bits + bits_in_first) / 8) bytes, but
  // writing a fixed 8 bytes (like the C version's 64-bit store) is
  // simpler and safe because ensure_space reserves headroom.
  self.storage[byte_pos] = (v & 0xFFUL).to_byte()
  self.storage[byte_pos + 1] = ((v >> 8) & 0xFFUL).to_byte()
  self.storage[byte_pos + 2] = ((v >> 16) & 0xFFUL).to_byte()
  self.storage[byte_pos + 3] = ((v >> 24) & 0xFFUL).to_byte()
  self.storage[byte_pos + 4] = ((v >> 32) & 0xFFUL).to_byte()
  self.storage[byte_pos + 5] = ((v >> 40) & 0xFFUL).to_byte()
  self.storage[byte_pos + 6] = ((v >> 48) & 0xFFUL).to_byte()
  self.storage[byte_pos + 7] = ((v >> 56) & 0xFFUL).to_byte()
  self.pos += n_bits
}

///|
/// Pad the bit position to the next byte boundary with zero bits.
fn BrotliBitWriter::align_to_byte(self : BrotliBitWriter) -> Unit {
  let remainder = self.pos & 7
  if remainder > 0 {
    self.pos += 8 - remainder
  }
}

///|
/// Extract the written bytes as an immutable `Bytes` value and reset
/// the writer for reuse.
fn BrotliBitWriter::take_output(self : BrotliBitWriter) -> Bytes {
  let n = (self.pos + 7) >> 3
  if n == 0 {
    return Bytes::default()
  }
  let result = @blit.make_uninit(n)
  @blit.blit_fixed_array(result, 0, self.storage, 0, n)
  // Reset for reuse.
  self.pos = 0
  // Zero out the region we just consumed so future writes start clean.
  for i in 0..<n {
    self.storage[i] = b'\x00'
  }
  result.unsafe_reinterpret_as_bytes()
}

///|
/// Current byte position (number of complete bytes written so far).
fn BrotliBitWriter::byte_pos(self : BrotliBitWriter) -> Int {
  self.pos >> 3
}

///|
/// Current bit position.
fn BrotliBitWriter::bit_pos(self : BrotliBitWriter) -> Int {
  self.pos
}

///|
test "bit_writer: brotli hello header" {
  let bw = BrotliBitWriter::new()
  // WBITS=22: bit0=1, bits1-3=5(=101)
  bw.write_bits(1, 1UL)
  bw.write_bits(3, 5UL)
  // ISLAST=0
  bw.write_bits(1, 0UL)
  // MNIBBLES=0
  bw.write_bits(2, 0UL)
  // MLEN=4 as 16 bits
  bw.write_bits(16, 4UL)
  // ISUNCOMPRESSED=1
  bw.write_bits(1, 1UL)
  // Align
  bw.align_to_byte()
  // Raw bytes: hello
  bw.write_bits(8, 0x68UL)
  bw.write_bits(8, 0x65UL)
  bw.write_bits(8, 0x6CUL)
  bw.write_bits(8, 0x6CUL)
  bw.write_bits(8, 0x6FUL)
  // Last empty metablock
  bw.write_bits(1, 1UL)
  bw.write_bits(1, 1UL)
  bw.align_to_byte()
  let out = bw.take_output()
  let bytes_arr : Array[Int] = []
  for i in 0..<out.length() {
    bytes_arr.push(out[i].to_int())
  }
  println("Brotli hello: \{bytes_arr}")
  // Expected: [0x0B, 0x02, 0x80, 0x68, 0x65, 0x6C, 0x6C, 0x6F, 0x03]
  assert_eq!(out[0].to_int(), 0x0B)
  assert_eq!(out[1].to_int(), 0x02)
  assert_eq!(out[2].to_int(), 0x80)
  assert_eq!(out.length(), 9)
}
