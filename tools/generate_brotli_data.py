#!/usr/bin/env python3
"""Generate Brotli static tables for the pure MoonBit port.

Regenerate with:
  python3 tools/generate_brotli_data.py

Verify the checked-in files are up to date with:
  python3 tools/generate_brotli_data.py --check
"""

from __future__ import annotations

import argparse
import ast
import re
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
VENDOR_COMMON = REPO_ROOT / "vendor" / "brotli" / "c" / "common"
VENDOR_DEC = REPO_ROOT / "vendor" / "brotli" / "c" / "dec"
BROTLI_DIR = REPO_ROOT / "brotli"


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def parse_number_list(body: str) -> list[int]:
    cleaned = re.sub(r"/\*.*?\*/", " ", body, flags=re.S)
    return [int(part.strip(), 0) for part in cleaned.replace("\n", " ").split(",") if part.strip()]


def parse_braced_numbers(text: str, marker: str) -> list[int]:
    pattern = re.escape(marker) + r".*?\{([^}]*)\}"
    match = re.search(pattern, text, re.S)
    if not match:
        raise SystemExit(f"could not find numeric initializer after marker: {marker}")
    return parse_number_list(match.group(1))


def parse_named_number_list(body: str, names: dict[str, int]) -> list[int]:
    body = re.sub(r"/\*.*?\*/", " ", body, flags=re.S)
    values: list[int] = []
    for raw_part in body.replace("\n", " ").split(","):
        part = raw_part.strip()
        if not part:
            continue
        if part in names:
          values.append(names[part])
        else:
          values.append(int(part, 0))
    return values


def parse_braced_named_numbers(text: str, marker: str, names: dict[str, int]) -> list[int]:
    pattern = re.escape(marker) + r".*?\{([^}]*)\}"
    match = re.search(pattern, text, re.S)
    if not match:
        raise SystemExit(f"could not find named initializer after marker: {marker}")
    return parse_named_number_list(match.group(1), names)


def parse_string_literals(text: str, marker: str) -> bytes:
    pattern = re.escape(marker) + r".*?=\s*(.*?);"
    match = re.search(pattern, text, re.S)
    if not match:
        raise SystemExit(f"could not find string initializer after marker: {marker}")
    section = match.group(1)
    literals = re.findall(r'"(?:[^"\\]|\\.)*"', section)
    if not literals:
        raise SystemExit(f"no string literals found for marker: {marker}")
    return b"".join(ast.literal_eval("b" + literal) for literal in literals)


def parse_context_lookup_table(text: str) -> list[int]:
    pattern = r"_kBrotliContextLookupTable\[\d+\]\s*=\s*\{(.*?)\};"
    match = re.search(pattern, text, re.S)
    if not match:
        raise SystemExit("could not find _kBrotliContextLookupTable")
    return parse_number_list(match.group(1))


def parse_prefix_code_ranges(text: str) -> tuple[list[int], list[int]]:
    pattern = r"_kBrotliPrefixCodeRanges\[[^\]]+\]\s*=\s*\{(.*?)\};"
    match = re.search(pattern, text, re.S)
    if not match:
        raise SystemExit("could not find _kBrotliPrefixCodeRanges")
    offsets: list[int] = []
    nbits: list[int] = []
    for offset_text, nbits_text in re.findall(r"\{\s*(\d+)\s*,\s*(\d+)\s*\}", match.group(1)):
        offsets.append(int(offset_text))
        nbits.append(int(nbits_text))
    return offsets, nbits


def parse_transform_type_names(text: str) -> dict[str, int]:
    pattern = r"enum BrotliWordTransformType\s*\{(.*?)BROTLI_NUM_TRANSFORM_TYPES"
    match = re.search(pattern, text, re.S)
    if not match:
        raise SystemExit("could not find BrotliWordTransformType enum")
    values: dict[str, int] = {}
    current = 0
    for raw_line in match.group(1).splitlines():
        line = raw_line.split("/*", 1)[0].strip().rstrip(",")
        if not line:
            continue
        if "=" in line:
            name, value = [part.strip() for part in line.split("=", 1)]
            current = int(value, 0)
        else:
            name = line
        values[name] = current
        current += 1
    return values


def encode_bytes_literal(data: bytes) -> str:
    return "".join(f"\\x{byte:02x}" for byte in data)


def format_int_array(values: list[int], indent: str = "  ", per_line: int = 8) -> str:
    lines = ["["]
    for i in range(0, len(values), per_line):
        chunk = values[i:i + per_line]
        body = ", ".join(str(value) for value in chunk)
        suffix = "," if i + per_line < len(values) else ""
        lines.append(f"{indent}{body}{suffix}")
    lines.append("]")
    return "\n".join(lines)


def format_bytes_builder(name: str, data: bytes, chunk_size: int = 64) -> str:
    lines = [f"let {name} : Bytes = {{", f"  let buf = @buffer.new(size_hint={len(data)})"]
    for i in range(0, len(data), chunk_size):
        chunk = data[i:i + chunk_size]
        lines.append(f'  buf.write_bytes(b"{encode_bytes_literal(chunk)}")')
    lines.append("  buf.to_bytes()")
    lines.append("}")
    return "\n".join(lines)


def build_command_lut() -> dict[str, list[int]]:
    insert_length_extra_bits = [
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x01,
        0x02, 0x02, 0x03, 0x03, 0x04, 0x04, 0x05, 0x05,
        0x06, 0x07, 0x08, 0x09, 0x0A, 0x0C, 0x0E, 0x18,
    ]
    copy_length_extra_bits = [
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x01, 0x01, 0x02, 0x02, 0x03, 0x03, 0x04, 0x04,
        0x05, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x18,
    ]
    cell_pos = [0, 1, 0, 1, 8, 9, 2, 16, 10, 17, 18]

    insert_length_offsets = [0]
    copy_length_offsets = [2]
    for i in range(23):
        insert_length_offsets.append(insert_length_offsets[i] + (1 << insert_length_extra_bits[i]))
        copy_length_offsets.append(copy_length_offsets[i] + (1 << copy_length_extra_bits[i]))

    cmd_insert_len_extra_bits: list[int] = []
    cmd_copy_len_extra_bits: list[int] = []
    cmd_distance_code: list[int] = []
    cmd_context: list[int] = []
    cmd_insert_len_offset: list[int] = []
    cmd_copy_len_offset: list[int] = []

    for symbol in range(704):
        cell_idx = symbol >> 6
        cell = cell_pos[cell_idx]
        copy_code = ((cell << 3) & 0x18) + (symbol & 0x7)
        copy_len_offset = copy_length_offsets[copy_code]
        insert_code = (cell & 0x18) + ((symbol >> 3) & 0x7)

        cmd_copy_len_extra_bits.append(copy_length_extra_bits[copy_code])
        cmd_context.append(3 if copy_len_offset > 4 else copy_len_offset - 2)
        cmd_copy_len_offset.append(copy_len_offset)
        cmd_distance_code.append(-1 if cell_idx >= 2 else 0)
        cmd_insert_len_extra_bits.append(insert_length_extra_bits[insert_code])
        cmd_insert_len_offset.append(insert_length_offsets[insert_code])

    return {
        "insert_length_extra_bits": insert_length_extra_bits,
        "copy_length_extra_bits": copy_length_extra_bits,
        "insert_length_offsets": insert_length_offsets,
        "copy_length_offsets": copy_length_offsets,
        "cmd_insert_len_extra_bits": cmd_insert_len_extra_bits,
        "cmd_copy_len_extra_bits": cmd_copy_len_extra_bits,
        "cmd_distance_code": cmd_distance_code,
        "cmd_context": cmd_context,
        "cmd_insert_len_offset": cmd_insert_len_offset,
        "cmd_copy_len_offset": cmd_copy_len_offset,
    }


def generate_dictionary_file(size_bits: list[int], offsets: list[int], data: bytes) -> str:
    return "\n".join([
        "///|",
        "/// Generated by `python3 tools/generate_brotli_data.py`. Do not edit by hand.",
        "let static_dictionary_size : Int = 122784",
        "",
        "///|",
        "let dictionary_size_bits_by_length : FixedArray[Int] = " + format_int_array(size_bits, per_line=8),
        "",
        "///|",
        "let dictionary_offsets_by_length : FixedArray[Int] = " + format_int_array(offsets, per_line=8),
        "",
        "///|",
        format_bytes_builder("dictionary_data", data),
        "",
        "///|",
        "pub fn static_dictionary_bytes() -> Bytes {",
        "  dictionary_data",
        "}",
        "",
        "///|",
        "pub fn static_dictionary_word_offset(length : Int) -> Int {",
        "  dictionary_offsets_by_length[length]",
        "}",
        "",
        "///|",
        "pub fn static_dictionary_size_bits(length : Int) -> Int {",
        "  dictionary_size_bits_by_length[length]",
        "}",
        "",
        "///|",
        "pub fn static_dictionary_num_bytes() -> Int {",
        "  static_dictionary_size",
        "}",
        "",
    ])


def generate_context_file(context_lookup: list[int]) -> str:
    return "\n".join([
        "///|",
        "/// Generated by `python3 tools/generate_brotli_data.py`. Do not edit by hand.",
        "let literal_context_lookup_size : Int = 2048",
        "",
        "///|",
        format_bytes_builder("literal_context_lookup_table", bytes(context_lookup)),
        "",
        "///|",
        "pub fn literal_context_lookup(index : Int) -> Byte {",
        "  literal_context_lookup_table[index]",
        "}",
        "",
        "///|",
        "pub fn literal_context_lookup_len() -> Int {",
        "  literal_context_lookup_size",
        "}",
        "",
    ])


def generate_transform_file(
    prefix_suffix: bytes,
    prefix_suffix_map: list[int],
    transforms: list[int],
) -> str:
    triplet_count = len(transforms) // 3
    cutoff_transform_ids = [0]
    for omit_last in range(1, 10):
        triplet_index = -1
        for i in range(triplet_count):
            base = i * 3
            prefix_id = transforms[base]
            transform_type = transforms[base + 1]
            suffix_id = transforms[base + 2]
            if prefix_id == 0 and transform_type == omit_last and suffix_id == 0:
                triplet_index = i
                break
        cutoff_transform_ids.append(triplet_index)

    return "\n".join([
        "///|",
        "/// Generated by `python3 tools/generate_brotli_data.py`. Do not edit by hand.",
        f"let num_word_transforms : Int = {triplet_count}",
        "",
        "///|",
        format_bytes_builder("transform_prefix_suffix_data", prefix_suffix, chunk_size=48),
        "",
        "///|",
        "let transform_prefix_suffix_map : FixedArray[Int] = " + format_int_array(prefix_suffix_map, per_line=10),
        "",
        "///|",
        "let transform_triplets : FixedArray[Int] = " + format_int_array(transforms, per_line=9),
        "",
        "///|",
        "let cutoff_transform_ids : FixedArray[Int] = " + format_int_array(cutoff_transform_ids, per_line=10),
        "",
        "///|",
        "pub fn transform_count() -> Int {",
        "  num_word_transforms",
        "}",
        "",
        "///|",
        "pub fn transform_prefix_suffix_bytes() -> Bytes {",
        "  transform_prefix_suffix_data",
        "}",
        "",
        "///|",
        "pub fn transform_prefix_suffix_offset(id : Int) -> Int {",
        "  transform_prefix_suffix_map[id]",
        "}",
        "",
        "///|",
        "pub fn transform_triplet_value(index : Int) -> Int {",
        "  transform_triplets[index]",
        "}",
        "",
        "///|",
        "pub fn cutoff_transform_id(index : Int) -> Int {",
        "  cutoff_transform_ids[index]",
        "}",
        "",
    ])


def generate_prefix_file(prefix_offsets: list[int], prefix_nbits: list[int], cmd_lut: dict[str, list[int]]) -> str:
    return "\n".join([
        "///|",
        "/// Generated by `python3 tools/generate_brotli_data.py`. Do not edit by hand.",
        "",
        "///|",
        "let block_length_prefix_offsets : FixedArray[Int] = " + format_int_array(prefix_offsets, per_line=8),
        "",
        "///|",
        "let block_length_prefix_nbits : FixedArray[Int] = " + format_int_array(prefix_nbits, per_line=8),
        "",
        "///|",
        "let insert_length_extra_bits : FixedArray[Int] = " + format_int_array(cmd_lut["insert_length_extra_bits"], per_line=8),
        "",
        "///|",
        "let copy_length_extra_bits : FixedArray[Int] = " + format_int_array(cmd_lut["copy_length_extra_bits"], per_line=8),
        "",
        "///|",
        "let insert_length_offsets : FixedArray[Int] = " + format_int_array(cmd_lut["insert_length_offsets"], per_line=8),
        "",
        "///|",
        "let copy_length_offsets : FixedArray[Int] = " + format_int_array(cmd_lut["copy_length_offsets"], per_line=8),
        "",
        "///|",
        "let command_insert_len_extra_bits : FixedArray[Int] = " + format_int_array(cmd_lut["cmd_insert_len_extra_bits"], per_line=16),
        "",
        "///|",
        "let command_copy_len_extra_bits : FixedArray[Int] = " + format_int_array(cmd_lut["cmd_copy_len_extra_bits"], per_line=16),
        "",
        "///|",
        "let command_distance_code : FixedArray[Int] = " + format_int_array(cmd_lut["cmd_distance_code"], per_line=16),
        "",
        "///|",
        "let command_context_id : FixedArray[Int] = " + format_int_array(cmd_lut["cmd_context"], per_line=16),
        "",
        "///|",
        "let command_insert_len_offset : FixedArray[Int] = " + format_int_array(cmd_lut["cmd_insert_len_offset"], per_line=16),
        "",
        "///|",
        "let command_copy_len_offset : FixedArray[Int] = " + format_int_array(cmd_lut["cmd_copy_len_offset"], per_line=16),
        "",
        "///|",
        "pub fn block_length_prefix_offset(symbol : Int) -> Int {",
        "  block_length_prefix_offsets[symbol]",
        "}",
        "",
        "///|",
        "pub fn block_length_prefix_extra_bits(symbol : Int) -> Int {",
        "  block_length_prefix_nbits[symbol]",
        "}",
        "",
        "///|",
        "pub fn insert_length_extra_bits_for_code(code : Int) -> Int {",
        "  insert_length_extra_bits[code]",
        "}",
        "",
        "///|",
        "pub fn copy_length_extra_bits_for_code(code : Int) -> Int {",
        "  copy_length_extra_bits[code]",
        "}",
        "",
        "///|",
        "pub fn insert_length_offset_for_code(code : Int) -> Int {",
        "  insert_length_offsets[code]",
        "}",
        "",
        "///|",
        "pub fn copy_length_offset_for_code(code : Int) -> Int {",
        "  copy_length_offsets[code]",
        "}",
        "",
        "///|",
        "pub fn command_insert_extra_bits(symbol : Int) -> Int {",
        "  command_insert_len_extra_bits[symbol]",
        "}",
        "",
        "///|",
        "pub fn command_copy_extra_bits(symbol : Int) -> Int {",
        "  command_copy_len_extra_bits[symbol]",
        "}",
        "",
        "///|",
        "pub fn command_distance_short_code(symbol : Int) -> Int {",
        "  command_distance_code[symbol]",
        "}",
        "",
        "///|",
        "pub fn command_context(symbol : Int) -> Int {",
        "  command_context_id[symbol]",
        "}",
        "",
        "///|",
        "pub fn command_insert_offset(symbol : Int) -> Int {",
        "  command_insert_len_offset[symbol]",
        "}",
        "",
        "///|",
        "pub fn command_copy_offset(symbol : Int) -> Int {",
        "  command_copy_len_offset[symbol]",
        "}",
        "",
    ])


def write_file(path: Path, content: str, check: bool) -> None:
    if check:
        if not path.exists():
            raise SystemExit(f"missing generated file: {path}")
        if path.read_text(encoding="utf-8") != content:
            raise SystemExit(f"out of date generated file: {path}")
        return
    path.write_text(content, encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="verify generated files are up to date")
    args = parser.parse_args()

    dictionary_c = read_text(VENDOR_COMMON / "dictionary.c")
    dictionary_bin = (VENDOR_COMMON / "dictionary.bin").read_bytes()
    transform_c = read_text(VENDOR_COMMON / "transform.c")
    transform_h = read_text(VENDOR_COMMON / "transform.h")
    context_c = read_text(VENDOR_COMMON / "context.c")
    constants_c = read_text(VENDOR_COMMON / "constants.c")

    size_bits = parse_braced_numbers(dictionary_c, "/* size_bits_by_length */")
    offsets = parse_braced_numbers(dictionary_c, "/* offsets_by_length */")
    prefix_suffix = parse_string_literals(transform_c, "char kPrefixSuffix")
    prefix_suffix_map = parse_braced_numbers(transform_c, "kPrefixSuffixMap[50]")
    transform_type_names = parse_transform_type_names(transform_h)
    transforms = parse_braced_named_numbers(transform_c, "kTransformsData[]", transform_type_names)
    context_lookup = parse_context_lookup_table(context_c)
    prefix_offsets, prefix_nbits = parse_prefix_code_ranges(constants_c)
    command_lut = build_command_lut()

    if len(size_bits) != 32 or len(offsets) != 32:
        raise SystemExit("unexpected dictionary table lengths")
    if len(context_lookup) != 2048:
        raise SystemExit("unexpected context lookup size")
    if len(prefix_offsets) != 26 or len(prefix_nbits) != 26:
        raise SystemExit("unexpected prefix range count")
    if len(transforms) % 3 != 0:
        raise SystemExit("transform triplets must be divisible by 3")
    if len(dictionary_bin) != 122784:
        raise SystemExit("unexpected dictionary size")

    BROTLI_DIR.mkdir(parents=True, exist_ok=True)
    write_file(BROTLI_DIR / "dictionary_data.mbt", generate_dictionary_file(size_bits, offsets, dictionary_bin), args.check)
    write_file(BROTLI_DIR / "context_data.mbt", generate_context_file(context_lookup), args.check)
    write_file(BROTLI_DIR / "transform_data.mbt", generate_transform_file(prefix_suffix, prefix_suffix_map, transforms), args.check)
    write_file(BROTLI_DIR / "prefix_data.mbt", generate_prefix_file(prefix_offsets, prefix_nbits, command_lut), args.check)
    return 0


if __name__ == "__main__":
    sys.exit(main())
