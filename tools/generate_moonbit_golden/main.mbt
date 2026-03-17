///|
#borrow(path)
extern "c" fn fopen_write(path : Bytes) -> Int64 = "golden_fopen_write"

///|
#borrow(path)
extern "c" fn fopen_read(path : Bytes) -> Int64 = "golden_fopen_read"

///|
#borrow(buf)
extern "c" fn fread_into(
  handle : Int64,
  buf : FixedArray[Byte],
  max_len : Int,
) -> Int = "golden_fread"

///|
#borrow(data)
extern "c" fn fwrite_bytes(handle : Int64, data : Bytes, len : Int) -> Unit = "golden_fwrite"

///|
extern "c" fn fclose(handle : Int64) -> Unit = "golden_fclose"

///|
extern "c" fn file_size(handle : Int64) -> Int64 = "golden_file_size"

///|
fn path_to_cstr(s : String) -> Bytes {
  Bytes::makei(s.length() + 1, fn(i) {
    if i < s.length() {
      s[i].to_int().to_byte()
    } else {
      b'\x00'
    }
  })
}

///|
fn read_file(path : String) -> Bytes {
  let h = fopen_read(path_to_cstr(path))
  if h == 0L {
    println("ERROR: cannot open \{path}")
    return Bytes::default()
  }
  let size = file_size(h).to_int()
  if size == 0 {
    fclose(h)
    return Bytes::default()
  }
  let buf = FixedArray::make(size, b'\x00')
  let n = fread_into(h, buf, size)
  fclose(h)
  if n != size {
    println("WARNING: read \{n} bytes, expected \{size}")
  }
  Bytes::makei(n, fn(i) { buf[i] })
}

///|
fn write_file(path : String, data : Bytes) -> Unit {
  let h = fopen_write(path_to_cstr(path))
  if h == 0L {
    println("ERROR: cannot open \{path} for writing")
    return
  }
  fwrite_bytes(h, data, data.length())
  fclose(h)
}

///|
struct Entry {
  name : String
  algorithm : String
  level : Int
  input_file : String
  output_file : String
  input_size : Int
  output_size : Int
}

///|
fn Entry::to_json(self : Entry) -> String {
  let buf = @buffer.new()
  buf.write_string("  {\n")
  buf.write_string("    \"name\": \"\{self.name}\",\n")
  buf.write_string("    \"algorithm\": \"\{self.algorithm}\",\n")
  if self.level != 0 {
    buf.write_string("    \"level\": \{self.level},\n")
  }
  buf.write_string("    \"input_file\": \"\{self.input_file}\",\n")
  buf.write_string("    \"output_file\": \"\{self.output_file}\",\n")
  buf.write_string("    \"input_size\": \{self.input_size},\n")
  buf.write_string("    \"output_size\": \{self.output_size}\n")
  buf.write_string("  }")
  buf.to_string()
}

///|
fn flate_level(level : Int) -> @flate.CompressionLevel {
  match level {
    1 => BestSpeed
    9 => BestCompression
    _ => Level(level)
  }
}

///|
fn main {
  let args = @env.args()
  let out_dir = if args.length() > 1 {
    args[1]
  } else {
    "testdata/moonbit_golden"
  }
  let golden_dir = if args.length() > 2 { args[2] } else { "testdata/golden" }
  // Input names and files (must match Go generator)
  let input_names = ["empty", "hello", "repeated", "zeros_10k", "mixed_1k"]
  let entries : Array[Entry] = []
  // Read inputs from existing golden input files
  let inputs : Array[(String, Bytes)] = []
  for name in input_names {
    let data = read_file("\{golden_dir}/\{name}.bin")
    inputs.push((name, data))
  }
  // DEFLATE
  for pair in inputs {
    let (name, data) = pair
    for level in [1, 6, 9] {
      let out_name = "deflate_\{name}_level\{level}.bin"
      let compressed = @flate.compress(data, level=flate_level(level)) catch {
        e => {
          println("ERROR deflate \{name} level\{level}: \{e}")
          continue
        }
      }
      write_file("\{out_dir}/\{out_name}", compressed)
      entries.push({
        name: "deflate/\{name}/level\{level}",
        algorithm: "deflate",
        level,
        input_file: "\{name}.bin",
        output_file: out_name,
        input_size: data.length(),
        output_size: compressed.length(),
      })
    }
  }
  // Gzip
  for pair in inputs {
    let (name, data) = pair
    for level in [1, 6, 9] {
      let out_name = "gzip_\{name}_level\{level}.bin"
      let compressed = @gzip.compress(data, level=flate_level(level)) catch {
        e => {
          println("ERROR gzip \{name} level\{level}: \{e}")
          continue
        }
      }
      write_file("\{out_dir}/\{out_name}", compressed)
      entries.push({
        name: "gzip/\{name}/level\{level}",
        algorithm: "gzip",
        level,
        input_file: "\{name}.bin",
        output_file: out_name,
        input_size: data.length(),
        output_size: compressed.length(),
      })
    }
  }
  // Zlib
  for pair in inputs {
    let (name, data) = pair
    for level in [1, 6, 9] {
      let out_name = "zlib_\{name}_level\{level}.bin"
      let compressed = @zlib.compress(data, level=flate_level(level)) catch {
        e => {
          println("ERROR zlib \{name} level\{level}: \{e}")
          continue
        }
      }
      write_file("\{out_dir}/\{out_name}", compressed)
      entries.push({
        name: "zlib/\{name}/level\{level}",
        algorithm: "zlib",
        level,
        input_file: "\{name}.bin",
        output_file: out_name,
        input_size: data.length(),
        output_size: compressed.length(),
      })
    }
  }
  // LZW (LSB order, litWidth=8, like Go)
  for pair in inputs {
    let (name, data) = pair
    if data.length() == 0 {
      continue
    }
    let out_name = "lzw_\{name}.bin"
    let compressed = @lzw.compress(data, @lzw.LSB, 8) catch {
      e => {
        println("ERROR lzw \{name}: \{e}")
        continue
      }
    }
    write_file("\{out_dir}/\{out_name}", compressed)
    entries.push({
      name: "lzw/\{name}",
      algorithm: "lzw",
      level: 0,
      input_file: "\{name}.bin",
      output_file: out_name,
      input_size: data.length(),
      output_size: compressed.length(),
    })
  }
  // Bzip2
  for pair in inputs {
    let (name, data) = pair
    if data.length() == 0 {
      continue
    }
    for level in [1, 9] {
      let out_name = "bzip2_\{name}_level\{level}.bin"
      let compressed = @bzip2.compress(data, level~) catch {
        e => {
          println("ERROR bzip2 \{name} level\{level}: \{e}")
          continue
        }
      }
      write_file("\{out_dir}/\{out_name}", compressed)
      entries.push({
        name: "bzip2/\{name}/level\{level}",
        algorithm: "bzip2",
        level,
        input_file: "\{name}.bin",
        output_file: out_name,
        input_size: data.length(),
        output_size: compressed.length(),
      })
    }
  }
  // Snappy
  for pair in inputs {
    let (name, data) = pair
    if data.length() == 0 {
      continue
    }
    let out_name = "snappy_\{name}.bin"
    let compressed = @snappy.compress(data)
    write_file("\{out_dir}/\{out_name}", compressed)
    entries.push({
      name: "snappy/\{name}",
      algorithm: "snappy",
      level: 0,
      input_file: "\{name}.bin",
      output_file: out_name,
      input_size: data.length(),
      output_size: compressed.length(),
    })
  }
  // LZ4
  for pair in inputs {
    let (name, data) = pair
    if data.length() == 0 {
      continue
    }
    let out_name = "lz4_\{name}.bin"
    let compressed = @lz4.compress(data)
    write_file("\{out_dir}/\{out_name}", compressed)
    entries.push({
      name: "lz4/\{name}",
      algorithm: "lz4",
      level: 0,
      input_file: "\{name}.bin",
      output_file: out_name,
      input_size: data.length(),
      output_size: compressed.length(),
    })
  }
  // Zstandard
  for pair in inputs {
    let (name, data) = pair
    if data.length() == 0 {
      continue
    }
    let out_name = "zstd_\{name}.bin"
    let compressed = @zstd.compress(data)
    write_file("\{out_dir}/\{out_name}", compressed)
    entries.push({
      name: "zstd/\{name}",
      algorithm: "zstd",
      level: 0,
      input_file: "\{name}.bin",
      output_file: out_name,
      input_size: data.length(),
      output_size: compressed.length(),
    })
  }
  // Write manifest
  let manifest = @buffer.new()
  manifest.write_string("[\n")
  for i, e in entries {
    if i > 0 {
      manifest.write_string(",\n")
    }
    manifest.write_string(e.to_json())
  }
  manifest.write_string("\n]\n")
  write_file(
    "\{out_dir}/manifest.json",
    Bytes::makei(manifest.to_string().length(), fn(i) {
      manifest.to_string()[i].to_int().to_byte()
    }),
  )
  println("Generated \{entries.length()} MoonBit golden files in \{out_dir}")
}
