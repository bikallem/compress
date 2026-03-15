///| Native target: Bytes length silently wraps at 2^28 (256MB).
///|
///| The native runtime's object header packs array length into 28 bits
///| of a uint32_t (see moonbit.h, Moonbit_make_array_header macro).
///| Any Bytes/FixedArray/String >= 268,435,456 elements stores a
///| truncated length, causing bounds-check aborts or silent corruption.
///|
///| Reproduce:
///|   moon run src/ --target native    # crashes with SIGABRT
///|   moon run src/                    # works fine (wasm-gc has no 28-bit limit)

fn main {
  let size = 268_435_456 // 2^28 — exactly the overflow point
  let b = Bytes::make(size, 42)
  println("requested size = \{size}")
  println("actual length  = \{b.length()}")
  println("b[0] = \{b[0]}")
}
