#!/usr/bin/env python3
"""Generate MoonBit benchmark packages — one package per (codec, size) pair.

This gives each benchmark its own process, avoiding OOM for large sizes.
Hand-written packages (checksum, streaming) are left untouched.

Usage:
    python3 tools/gen_benchmarks.py
"""

import os
import shutil
import textwrap

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BENCH_DIR = os.path.join(REPO_ROOT, "benchmarks")
MODULE = "bikallem/compress"

# ---------------------------------------------------------------------------
# Size definitions
# ---------------------------------------------------------------------------

# NOTE: MoonBit native runtime truncates array length to 28 bits (max ~256MB).
# See https://github.com/moonbitlang/moonbit-docs/issues/1155
# In-memory benchmarks are capped at 100MB until this is fixed.
SIZES = [
    ("1kb",   1024),
    ("10kb",  10240),
    ("100kb", 102400),
    ("1mb",   1048576),
    ("10mb",  10485760),
    ("100mb", 104857600),
]

# ---------------------------------------------------------------------------
# Codec definitions
# ---------------------------------------------------------------------------

# Each codec defines:
#   pkg_import: the moon.pkg import block
#   helpers:    helper functions (compress_setup, bench_compress, bench_decompress)
#   benches:    list of (size_label, size_bytes, benchmark_code) tuples
#              If size_label is None, it's included in all size packages that
#              match one of the given sizes.

def flate_benches():
    """Generate flate benchmarks per size."""
    pkg_import_base = textwrap.dedent("""\
        import {
          "bikallem/compress/benchmarks",
          "bikallem/compress/flate" @fl,
          "moonbitlang/core/bench",
        }
    """)

    pkg_import_with_buffer = textwrap.dedent("""\
        import {
          "bikallem/compress/benchmarks",
          "bikallem/compress/flate" @fl,
          "moonbitlang/core/bench",
          "moonbitlang/core/buffer",
        }
    """)

    DICT_SIZES = {"10kb", "100kb"}

    # Use a function to pick the right import per size
    def get_pkg_import(label):
        return pkg_import_with_buffer if label in DICT_SIZES else pkg_import_base

    # Store as a callable on the outer scope
    pkg_import = get_pkg_import  # will be called per-size below

    base_helpers = textwrap.dedent("""\
        ///|
        fn compress_setup(
          size : Int,
          gen? : (Int) -> Bytes = @benchmarks.gen_text,
        ) -> Bytes raise {
          @fl.compress(gen(size))
        }

        ///|
        fn bench_compress(
          b : @bench.T,
          name~ : String,
          size : Int,
          level? : @fl.CompressionLevel = DefaultCompression,
          gen? : (Int) -> Bytes = @benchmarks.gen_text,
        ) -> Unit {
          let data = gen(size)
          b.bench(name~, fn() { b.keep(try! @fl.compress(data, level~)) })
        }

        ///|
        fn bench_decompress(
          b : @bench.T,
          name~ : String,
          size : Int,
          gen? : (Int) -> Bytes = @benchmarks.gen_text,
        ) -> Unit raise {
          let compressed = compress_setup(size, gen~)
          b.bench(name~, fn() { b.keep(try! @fl.decompress(compressed)) })
        }
    """)

    dict_helper = textwrap.dedent("""\

        ///|
        fn deflate_with_dict(data : Bytes, dict : Bytes) -> Bytes {
          let d = @fl.Deflater::new(dict~)
          let buf = @buffer.new()
          match d.encode(Some(data)) {
            Data(out) => buf.write_bytes(out)
            _ => ()
          }
          loop d.encode(None) {
            Data(out) => {
              buf.write_bytes(out)
              continue d.encode(None)
            }
            _ => break
          }
          buf.to_bytes()
        }
    """)

    def helpers_for(label):
        h = base_helpers
        if label in DICT_SIZES:
            h += dict_helper
        return h

    helpers = helpers_for  # will be called per-size below

    # Standard benchmarks: compress_default + decompress at every size
    standard = {}
    for label, size in SIZES:
        standard[label] = []
        standard[label].append(textwrap.dedent(f"""\
            ///|
            test "bench flate compress default text_{label}" (b : @bench.T) {{
              bench_compress(b, name="flate_compress_default_{label}", {size})
            }}
        """))
        standard[label].append(textwrap.dedent(f"""\
            ///|
            test "bench flate decompress text_{label}" (b : @bench.T) {{
              bench_decompress(b, name="flate_decompress_{label}", {size})
            }}
        """))

    # Extra benchmarks at specific sizes
    extras = {
        "1kb": [
            textwrap.dedent("""\
                ///|
                test "bench flate compress best_speed text_1kb" (b : @bench.T) {
                  bench_compress(b, name="flate_compress_speed_1kb", 1024, level=BestSpeed)
                }
            """),
        ],
        "10kb": [
            textwrap.dedent("""\
                ///|
                test "bench flate compress best_speed text_10kb" (b : @bench.T) {
                  bench_compress(b, name="flate_compress_speed_10kb", 10240, level=BestSpeed)
                }
            """),
            textwrap.dedent("""\
                ///|
                test "bench flate compress best_compression text_10kb" (b : @bench.T) {
                  bench_compress(
                    b,
                    name="flate_compress_best_10kb",
                    10240,
                    level=BestCompression,
                  )
                }
            """),
            textwrap.dedent("""\
                ///|
                test "bench flate compress zeros_10kb" (b : @bench.T) {
                  bench_compress(
                    b,
                    name="flate_compress_zeros_10kb",
                    10240,
                    gen=@benchmarks.gen_zeros,
                  )
                }
            """),
            textwrap.dedent("""\
                ///|
                test "bench flate compress random_10kb" (b : @bench.T) {
                  bench_compress(
                    b,
                    name="flate_compress_random_10kb",
                    10240,
                    level=BestSpeed,
                    gen=@benchmarks.gen_random,
                  )
                }
            """),
            textwrap.dedent("""\
                ///|
                test "bench flate decompress zeros_10kb" (b : @bench.T) {
                  bench_decompress(
                    b,
                    name="flate_decompress_zeros_10kb",
                    10240,
                    gen=@benchmarks.gen_zeros,
                  )
                }
            """),
            textwrap.dedent("""\
                ///|
                test "bench flate compress dict text_10kb" (b : @bench.T) {
                  let dict : Bytes = b"The quick brown fox jumps over the lazy dog. "
                  let data = @benchmarks.gen_text(10240)
                  b.bench(name="flate_compress_dict_10kb", fn() {
                    b.keep(deflate_with_dict(data, dict))
                  })
                }
            """),
        ],
        "100kb": [
            textwrap.dedent("""\
                ///|
                test "bench flate compress dict text_100kb" (b : @bench.T) {
                  let dict : Bytes = b"The quick brown fox jumps over the lazy dog. "
                  let data = @benchmarks.gen_text(102400)
                  b.bench(name="flate_compress_dict_100kb", fn() {
                    b.keep(deflate_with_dict(data, dict))
                  })
                }
            """),
        ],
    }

    # Merge
    for label in standard:
        standard[label].extend(extras.get(label, []))

    return pkg_import, helpers, standard


def gzip_benches():
    pkg_import = textwrap.dedent("""\
        import {
          "bikallem/compress/benchmarks",
          "bikallem/compress/flate",
          "bikallem/compress/gzip" @gz,
          "moonbitlang/core/bench",
        }
    """)

    helpers = textwrap.dedent("""\
        ///|
        fn compress_setup(size : Int) -> Bytes raise {
          @gz.compress(@benchmarks.gen_text(size))
        }

        ///|
        fn bench_compress(
          b : @bench.T,
          name~ : String,
          size : Int,
          level? : @flate.CompressionLevel = DefaultCompression,
        ) -> Unit {
          let data = @benchmarks.gen_text(size)
          b.bench(name~, fn() { b.keep(try! @gz.compress(data, level~)) })
        }

        ///|
        fn bench_decompress(b : @bench.T, name~ : String, size : Int) -> Unit raise {
          let compressed = compress_setup(size)
          b.bench(name~, fn() { b.keep(try! @gz.decompress(compressed)) })
        }
    """)

    standard = {}
    for label, size in SIZES:
        standard[label] = []
        standard[label].append(textwrap.dedent(f"""\
            ///|
            test "bench gzip compress default text_{label}" (b : @bench.T) {{
              bench_compress(b, name="gzip_compress_default_{label}", {size})
            }}
        """))
        standard[label].append(textwrap.dedent(f"""\
            ///|
            test "bench gzip decompress text_{label}" (b : @bench.T) {{
              bench_decompress(b, name="gzip_decompress_{label}", {size})
            }}
        """))

    extras = {
        "10kb": [
            textwrap.dedent("""\
                ///|
                test "bench gzip compress best_speed text_10kb" (b : @bench.T) {
                  bench_compress(b, name="gzip_compress_speed_10kb", 10240, level=BestSpeed)
                }
            """),
        ],
    }

    for label in standard:
        standard[label].extend(extras.get(label, []))

    return pkg_import, helpers, standard


def zlib_benches():
    pkg_import = textwrap.dedent("""\
        import {
          "bikallem/compress/benchmarks",
          "bikallem/compress/flate",
          "bikallem/compress/zlib" @zl,
          "moonbitlang/core/bench",
        }
    """)

    helpers = textwrap.dedent("""\
        ///|
        fn compress_setup(size : Int) -> Bytes raise {
          @zl.compress(@benchmarks.gen_text(size))
        }

        ///|
        fn bench_compress(
          b : @bench.T,
          name~ : String,
          size : Int,
          level? : @flate.CompressionLevel = DefaultCompression,
        ) -> Unit {
          let data = @benchmarks.gen_text(size)
          b.bench(name~, fn() { b.keep(try! @zl.compress(data, level~)) })
        }

        ///|
        fn bench_decompress(b : @bench.T, name~ : String, size : Int) -> Unit raise {
          let compressed = compress_setup(size)
          b.bench(name~, fn() { b.keep(try! @zl.decompress(compressed)) })
        }
    """)

    standard = {}
    for label, size in SIZES:
        standard[label] = []
        standard[label].append(textwrap.dedent(f"""\
            ///|
            test "bench zlib compress default text_{label}" (b : @bench.T) {{
              bench_compress(b, name="zlib_compress_default_{label}", {size})
            }}
        """))
        standard[label].append(textwrap.dedent(f"""\
            ///|
            test "bench zlib decompress text_{label}" (b : @bench.T) {{
              bench_decompress(b, name="zlib_decompress_{label}", {size})
            }}
        """))

    extras = {
        "10kb": [
            textwrap.dedent("""\
                ///|
                test "bench zlib compress best_speed text_10kb" (b : @bench.T) {
                  bench_compress(b, name="zlib_compress_speed_10kb", 10240, level=BestSpeed)
                }
            """),
        ],
    }

    for label in standard:
        standard[label].extend(extras.get(label, []))

    return pkg_import, helpers, standard


def lzw_benches():
    pkg_import = textwrap.dedent("""\
        import {
          "bikallem/compress/benchmarks",
          "bikallem/compress/lzw" @lw,
          "moonbitlang/core/bench",
        }
    """)

    helpers = textwrap.dedent("""\
        ///|
        fn compress_setup(size : Int) -> Bytes raise {
          @lw.compress(@benchmarks.gen_text(size), @lw.LSB, 8)
        }

        ///|
        fn bench_compress(b : @bench.T, name~ : String, size : Int) -> Unit {
          let data = @benchmarks.gen_text(size)
          b.bench(name~, fn() { b.keep(try! @lw.compress(data, @lw.LSB, 8)) })
        }

        ///|
        fn bench_decompress(b : @bench.T, name~ : String, size : Int) -> Unit raise {
          let compressed = compress_setup(size)
          b.bench(name~, fn() { b.keep(try! @lw.decompress(compressed, @lw.LSB, 8)) })
        }
    """)

    standard = {}
    for label, size in SIZES:
        standard[label] = []
        standard[label].append(textwrap.dedent(f"""\
            ///|
            test "bench lzw compress LSB text_{label}" (b : @bench.T) {{
              bench_compress(b, name="lzw_compress_lsb_{label}", {size})
            }}
        """))
        standard[label].append(textwrap.dedent(f"""\
            ///|
            test "bench lzw decompress LSB text_{label}" (b : @bench.T) {{
              bench_decompress(b, name="lzw_decompress_lsb_{label}", {size})
            }}
        """))

    return pkg_import, helpers, standard


def bzip2_benches():
    pkg_import = textwrap.dedent("""\
        import {
          "bikallem/compress/benchmarks",
          "bikallem/compress/bzip2" @bz2,
          "moonbitlang/core/bench",
        }
    """)

    helpers = textwrap.dedent("""\
        ///|
        fn compress_setup(size : Int) -> Bytes raise {
          @bz2.compress(@benchmarks.gen_text(size))
        }

        ///|
        fn bench_compress(b : @bench.T, name~ : String, size : Int) -> Unit {
          let data = @benchmarks.gen_text(size)
          b.bench(name~, fn() { b.keep(try! @bz2.compress(data)) })
        }

        ///|
        fn bench_decompress(b : @bench.T, name~ : String, size : Int) -> Unit raise {
          let compressed = compress_setup(size)
          b.bench(name~, fn() { b.keep(try! @bz2.decompress(compressed)) })
        }
    """)

    standard = {}
    for label, size in SIZES:
        standard[label] = []
        standard[label].append(textwrap.dedent(f"""\
            ///|
            test "bench bzip2 compress default text_{label}" (b : @bench.T) {{
              bench_compress(b, name="bzip2_compress_default_{label}", {size})
            }}
        """))
        standard[label].append(textwrap.dedent(f"""\
            ///|
            test "bench bzip2 decompress text_{label}" (b : @bench.T) {{
              bench_decompress(b, name="bzip2_decompress_{label}", {size})
            }}
        """))

    return pkg_import, helpers, standard


# ---------------------------------------------------------------------------
# Codecs to generate (streaming and checksum are hand-written)
# ---------------------------------------------------------------------------

CODECS = {
    "flate": flate_benches,
    "gzip":  gzip_benches,
    "zlib":  zlib_benches,
    "lzw":   lzw_benches,
    "bzip2": bzip2_benches,
}

# Hand-written packages that should not be touched
KEEP_PACKAGES = {"checksum", "streaming", "data.mbt", "moon.pkg"}

# ---------------------------------------------------------------------------
# Generate
# ---------------------------------------------------------------------------

def main():
    generated_pkgs = []

    # Remove old generated codec packages
    for entry in os.listdir(BENCH_DIR):
        path = os.path.join(BENCH_DIR, entry)
        if entry in KEEP_PACKAGES:
            continue
        if os.path.isdir(path):
            shutil.rmtree(path)
            print(f"  removed {entry}/")

    for codec, bench_fn in CODECS.items():
        pkg_import, helpers, size_benches = bench_fn()

        for label, _ in SIZES:
            if label not in size_benches:
                continue
            tests = size_benches[label]
            if not tests:
                continue

            pkg_name = f"{codec}-{label}"
            pkg_dir = os.path.join(BENCH_DIR, pkg_name)
            os.makedirs(pkg_dir, exist_ok=True)

            # pkg_import / helpers may be callable (per-size) or plain strings
            imp = pkg_import(label) if callable(pkg_import) else pkg_import
            hlp = helpers(label) if callable(helpers) else helpers

            # Write moon.pkg
            with open(os.path.join(pkg_dir, "moon.pkg"), "w") as f:
                f.write(imp)

            # Write bench .mbt file
            with open(os.path.join(pkg_dir, "bench.mbt"), "w") as f:
                f.write(hlp)
                for test_code in tests:
                    f.write("\n")
                    f.write(test_code)

            generated_pkgs.append(f"benchmarks/{pkg_name}")
            print(f"  generated {pkg_name}/")

    # Always include hand-written packages
    hand_written = [f"{MODULE}/benchmarks/checksum", f"{MODULE}/benchmarks/streaming"]

    all_pkgs = hand_written + [f"{MODULE}/{p}" for p in generated_pkgs]
    print(f"\nGenerated {len(generated_pkgs)} packages.")

    # Update bench.sh BENCH_PKGS array.
    # Uses fully-qualified names so moon's -p flag uses exact matching
    # instead of fuzzy matching.
    bench_sh = os.path.join(REPO_ROOT, "tools", "bench.sh")
    with open(bench_sh, "r") as f:
        content = f.read()

    import re
    array_body = "\n".join(f"  {p}" for p in all_pkgs)
    new_array = f"BENCH_PKGS=(\n{array_body}\n)"
    content = re.sub(
        r'BENCH_PKGS=\(.*?\)',
        new_array,
        content,
        flags=re.DOTALL,
    )

    with open(bench_sh, "w") as f:
        f.write(content)
    print(f"Updated {bench_sh}")


if __name__ == "__main__":
    main()
