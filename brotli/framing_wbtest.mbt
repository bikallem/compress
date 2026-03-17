///|
fn write_test_metadata_block(
  writer : BitWriter,
  is_last : Bool,
  metadata : BytesView,
) -> Unit raise BrotliError {
  let len = metadata.length()
  guard len <= max_meta_block_len else {
    raise BrotliError::CorruptInput("metadata block too large")
  }
  writer.write_bits((if is_last { 1 } else { 0 }).reinterpret_as_uint(), 1)
  if is_last {
    writer.write_bits(0U, 1)
  }
  writer.write_bits(3U, 2)
  writer.write_bits(0U, 1)
  if len == 0 {
    writer.write_bits(0U, 2)
  } else {
    let nbytes = (bit_length(len - 1) + 7) / 8
    writer.write_bits(nbytes.reinterpret_as_uint(), 2)
    writer.write_bits((len - 1).reinterpret_as_uint(), nbytes * 8)
  }
  writer.align_to_byte()
  writer.write_bytes(metadata)
}

///|
test "brotli window bits round trip" {
  for wbits in 10..<=24 {
    let writer = BitWriter::new()
    write_window_bits(writer, wbits) catch {
      e => abort(e.to_string())
    }
    let encoded = writer.finish()
    let reader = BitReader::new()
    reader.set_input(encoded[:])
    let decoded = read_window_bits(reader) catch { e => abort(e.to_string()) }
    assert_eq(decoded, Some(wbits))
  }
}

///|
test "brotli parses uncompressed metablock header" {
  let writer = BitWriter::new()
  write_uncompressed_block(writer, b"hello"[:]) catch {
    e => abort(e.to_string())
  }
  let encoded = writer.finish()
  let reader = BitReader::new()
  reader.set_input(encoded[:])
  let header = read_meta_block_header(reader) catch {
    e => abort(e.to_string())
  }
  match header {
    Some(h) => {
      assert_eq(h.is_last, false)
      assert_eq(h.is_last_empty, false)
      assert_eq(h.is_metadata, false)
      assert_eq(h.is_uncompressed, true)
      assert_eq(h.length, 5)
    }
    None => fail("expected metablock header")
  }
}

///|
test "brotli parses metadata metablock header" {
  let writer = BitWriter::new()
  write_test_metadata_block(writer, false, b"meta"[:]) catch {
    e => abort(e.to_string())
  }
  let encoded = writer.finish()
  let reader = BitReader::new()
  reader.set_input(encoded[:])
  let header = read_meta_block_header(reader) catch {
    e => abort(e.to_string())
  }
  match header {
    Some(h) => {
      assert_eq(h.is_last, false)
      assert_eq(h.is_last_empty, false)
      assert_eq(h.is_metadata, true)
      assert_eq(h.is_uncompressed, false)
      assert_eq(h.length, 4)
    }
    None => fail("expected metablock header")
  }
}

///|
test "brotli parses last empty metablock header" {
  let writer = BitWriter::new()
  write_last_empty_block(writer)
  let encoded = writer.finish()
  let reader = BitReader::new()
  reader.set_input(encoded[:])
  let header = read_meta_block_header(reader) catch {
    e => abort(e.to_string())
  }
  match header {
    Some(h) => {
      assert_eq(h.is_last, true)
      assert_eq(h.is_last_empty, true)
      assert_eq(h.length, 0)
    }
    None => fail("expected metablock header")
  }
}

///|
test "brotli skips metadata metablocks" {
  let writer = BitWriter::new()
  write_window_bits(writer, 16) catch {
    e => abort(e.to_string())
  }
  write_test_metadata_block(writer, false, b"meta"[:]) catch {
    e => abort(e.to_string())
  }
  write_uncompressed_block(writer, b"payload"[:]) catch {
    e => abort(e.to_string())
  }
  write_last_empty_block(writer)
  let stream = writer.finish()
  let decompressed = decompress(stream) catch { e => abort(e.to_string()) }
  assert_eq(decompressed, b"payload")
}
