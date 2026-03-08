///|
/// Count matching bytes between positions a and b, up to max_len.
/// Uses 8-byte-at-a-time comparison with CTZ for fast mismatch detection.
#borrow(data)
extern "c" fn match_len(data : Bytes, a : Int, b : Int, max_len : Int) -> Int = "bikallem_compress_flate_match_len"
