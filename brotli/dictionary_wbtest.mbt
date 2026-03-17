///|
test "brotli dictionary word lookup uses length tables" {
  assert_eq(dictionary_word_count(3), 0)
  assert_eq(dictionary_word_count(4), 1024)
  assert_eq(dictionary_word_count(24), 32)
  assert_eq(
    static_dictionary_word(4, 0) catch {
      e => abort(e.to_string())
    },
    b"time",
  )
  assert_eq(
    static_dictionary_word(4, 1) catch {
      e => abort(e.to_string())
    },
    b"down",
  )
  assert_eq(
    static_dictionary_word(5, 0) catch {
      e => abort(e.to_string())
    },
    b"first",
  )
  assert_eq(
    static_dictionary_word(8, 1) catch {
      e => abort(e.to_string())
    },
    b"business",
  )
}

///|
test "brotli word transforms apply expected RFC forms" {
  assert_eq(
    transform_word(b"time"[:], 0) catch {
      e => abort(e.to_string())
    },
    b"time",
  )
  assert_eq(
    transform_word(b"time"[:], 1) catch {
      e => abort(e.to_string())
    },
    b"time ",
  )
  assert_eq(
    transform_word(b"time"[:], 3) catch {
      e => abort(e.to_string())
    },
    b"ime",
  )
  assert_eq(
    transform_word(b"time"[:], 4) catch {
      e => abort(e.to_string())
    },
    b"Time ",
  )
  assert_eq(
    transform_word(b"time"[:], 12) catch {
      e => abort(e.to_string())
    },
    b"tim",
  )
  assert_eq(
    transform_word(b"time"[:], 44) catch {
      e => abort(e.to_string())
    },
    b"TIME",
  )
  assert_eq(
    transform_word(b"time"[:], 49) catch {
      e => abort(e.to_string())
    },
    b"timing ",
  )
}

///|
test "brotli Ferment transforms handle UTF-8 bytes like RFC" {
  assert_eq(
    transform_word(b"\xc3\xa9"[:], 9) catch {
      e => abort(e.to_string())
    },
    b"\xc3\x89",
  )
  assert_eq(
    transform_word(b"\xc3\xa9a"[:], 44) catch {
      e => abort(e.to_string())
    },
    b"\xc3\x89A",
  )
}

///|
test "brotli dictionary reference reconstructs transformed words" {
  assert_eq(
    static_dictionary_reference(4, 0) catch {
      e => abort(e.to_string())
    },
    b"time",
  )
  assert_eq(
    static_dictionary_reference(4, 4 << 10) catch {
      e => abort(e.to_string())
    },
    b"Time ",
  )
  assert_eq(
    static_dictionary_reference(5, 44 << 10) catch {
      e => abort(e.to_string())
    },
    b"FIRST",
  )
}

///|
test "brotli dictionary helpers reject invalid references" {
  let bad_length = try? static_dictionary_reference(3, 0)
  guard bad_length is Err(_) else { fail("expected invalid length error") }

  let bad_transform = try? static_dictionary_reference(
    4,
    transform_count() << 10,
  )
  guard bad_transform is Err(_) else {
    fail("expected invalid transform id error")
  }
}
