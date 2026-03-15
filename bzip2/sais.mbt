///|
/// SA-IS: Suffix Array Induced Sorting (Nong, Zhang, Chan 2009).
/// O(n) time and space suffix array construction.
///
/// Builds a suffix array for text[0..n-1] over alphabet [0..k-1].
/// text[n-1] MUST be the unique smallest character (sentinel = 0).
fn sais(text : FixedArray[Int], n : Int, k : Int) -> FixedArray[Int] {
  if n == 1 {
    return [0]
  }
  if n == 2 {
    // text[1] is sentinel (smallest), so SA = [1, 0]
    return [1, 0]
  }

  // Step 1: Classify suffixes as S-type (true) or L-type (false).
  let t = FixedArray::make(n, false)
  t.unsafe_set(n - 1, true) // sentinel is S-type
  for i = n - 2; i >= 0; i = i - 1 {
    t.unsafe_set(
      i,
      if text.unsafe_get(i) < text.unsafe_get(i + 1) {
        true // S-type
      } else if text.unsafe_get(i) > text.unsafe_get(i + 1) {
        false // L-type
      } else {
        t.unsafe_get(i + 1) // same char, inherit from next
      },
    )
  }

  // Helper: is position i an LMS suffix?
  // LMS = S-type whose predecessor is L-type. Position 0 is never LMS.
  fn is_lms(i : Int) -> Bool {
    i > 0 && t.unsafe_get(i) && !t.unsafe_get(i - 1)
  }

  // Step 2: Count character frequencies for bucket computation.
  let bkt = FixedArray::make(k, 0)
  for i in 0..<n {
    bkt.unsafe_set(text.unsafe_get(i), bkt.unsafe_get(text.unsafe_get(i)) + 1)
  }

  // Bucket boundary helpers.
  fn bucket_starts() -> FixedArray[Int] {
    let s = FixedArray::make(k, 0)
    let mut sum = 0
    for i in 0..<k {
      s.unsafe_set(i, sum)
      sum += bkt.unsafe_get(i)
    }
    s
  }

  fn bucket_ends() -> FixedArray[Int] {
    let e = FixedArray::make(k, 0)
    let mut sum = 0
    for i in 0..<k {
      sum += bkt.unsafe_get(i)
      e.unsafe_set(i, sum)
    }
    e
  }

  let sa = FixedArray::make(n, -1)

  // Step 3: Place LMS suffixes at bucket ends (right-to-left for stability).
  {
    let ends = bucket_ends()
    for i = n - 1; i >= 0; i = i - 1 {
      if is_lms(i) {
        let c = text.unsafe_get(i)
        let p = ends.unsafe_get(c) - 1
        ends.unsafe_set(c, p)
        sa.unsafe_set(p, i)
      }
    }
  }

  // Step 4: Induced sort L-type suffixes (left to right).
  {
    let starts = bucket_starts()
    for i in 0..<n {
      let j = sa.unsafe_get(i)
      if j > 0 && !t.unsafe_get(j - 1) {
        let c = text.unsafe_get(j - 1)
        let p = starts.unsafe_get(c)
        sa.unsafe_set(p, j - 1)
        starts.unsafe_set(c, p + 1)
      }
    }
  }

  // Step 5: Induced sort S-type suffixes (right to left).
  {
    let ends = bucket_ends()
    for i = n - 1; i >= 0; i = i - 1 {
      let j = sa.unsafe_get(i)
      if j > 0 && t.unsafe_get(j - 1) {
        let c = text.unsafe_get(j - 1)
        let p = ends.unsafe_get(c) - 1
        ends.unsafe_set(c, p)
        sa.unsafe_set(p, j - 1)
      }
    }
  }

  // Step 6: Compact sorted LMS suffixes into sa[0..n1-1].
  let mut n1 = 0
  for i in 0..<n {
    if is_lms(sa.unsafe_get(i)) {
      sa.unsafe_set(n1, sa.unsafe_get(i))
      n1 += 1
    }
  }

  // Step 7: Name LMS substrings.
  // Use the second half of SA as workspace for names.
  // names[i] = -1 means position i is not an LMS position.
  for i in n1..<n {
    sa.unsafe_set(i, -1)
  }

  let mut name = 0
  let mut prev = -1
  for i in 0..<n1 {
    let pos = sa.unsafe_get(i)
    // Compare LMS substring at `pos` with previous one at `prev`.
    let mut diff = false
    if prev == -1 {
      diff = true
    } else {
      // Compare character by character until we reach the end of both LMS substrings.
      diff = false
      for d = 0; ; d = d + 1 {
        // If characters or types differ, substrings are different.
        if text.unsafe_get(prev + d) != text.unsafe_get(pos + d) ||
          t.unsafe_get(prev + d) != t.unsafe_get(pos + d) {
          diff = true
          break
        }
        // After the first character, check if we've reached the end of either LMS substring.
        if d > 0 && (is_lms(prev + d) || is_lms(pos + d)) {
          // If exactly one is LMS end but not both, they differ.
          // If both are LMS end, they're equal up to here.
          diff = is_lms(prev + d) != is_lms(pos + d)
          break
        }
      } nobreak {
        ()
      }
    }
    if diff {
      name += 1
    }
    prev = pos
    // Store name in the second half of SA, indexed by pos/2.
    // LMS positions are at least 2 apart (L then S), so pos/2 is unique.
    // We store at sa[n1 + pos/2] to avoid overwriting compacted LMS in sa[0..n1-1].
    sa.unsafe_set(n1 + (pos >> 1), name - 1)
  }

  // Step 8: Collect the reduced string s1 and the LMS position map.
  let s1 = FixedArray::make(n1, 0)
  let lms_map = FixedArray::make(n1, 0)
  {
    let mut j = 0
    for i in n1..<n {
      if sa.unsafe_get(i) >= 0 {
        s1.unsafe_set(j, sa.unsafe_get(i))
        lms_map.unsafe_set(j, (i - n1) * 2) // recover original position from pos/2 index
        j += 1
      }
    }
    // Correct lms_map: the stored index is (i - n1) which was pos/2.
    // We need to recover pos. But we stored at sa[n1 + pos/2] = name.
    // So the position in the second half (i - n1) = pos/2, thus pos = 2*(i - n1).
    // But LMS positions can be odd too! We need a different approach.
  }

  // Actually, let me use a cleaner approach for the mapping.
  // Rebuild lms_map by scanning for LMS positions in order.
  {
    let mut j = 0
    for i in 0..<n {
      if is_lms(i) {
        lms_map.unsafe_set(j, i)
        j += 1
      }
    }
  }

  // Step 9: Recurse if names are not unique.
  if name < n1 {
    // Names are not unique — recurse.
    let sa1 = sais(s1, n1, name)
    // Map back: sa1[i] is an index into the reduced string.
    // lms_map[sa1[i]] gives the original text position.
    for i in 0..<n1 {
      s1.unsafe_set(i, lms_map.unsafe_get(sa1.unsafe_get(i)))
    }
    // s1 now contains sorted LMS positions in original text coordinates.
  } else {
    // Names are unique — directly compute the sorted order.
    // s1[i] = name of i-th LMS position. Names are unique, so inverse is trivial.
    let sorted = FixedArray::make(n1, 0)
    for i in 0..<n1 {
      sorted.unsafe_set(s1.unsafe_get(i), lms_map.unsafe_get(i))
    }
    FixedArray::unsafe_blit(s1, 0, sorted, 0, n1)
  }

  // Step 10: Place sorted LMS suffixes into SA at bucket ends.
  for i in 0..<n {
    sa.unsafe_set(i, -1)
  }
  {
    let ends = bucket_ends()
    // Place right-to-left for stability within buckets.
    for i = n1 - 1; i >= 0; i = i - 1 {
      let pos = s1.unsafe_get(i)
      let c = text.unsafe_get(pos)
      let p = ends.unsafe_get(c) - 1
      ends.unsafe_set(c, p)
      sa.unsafe_set(p, pos)
    }
  }

  // Step 11: Final induced sort.
  {
    let starts = bucket_starts()
    for i in 0..<n {
      let j = sa.unsafe_get(i)
      if j > 0 && !t.unsafe_get(j - 1) {
        let c = text.unsafe_get(j - 1)
        let p = starts.unsafe_get(c)
        sa.unsafe_set(p, j - 1)
        starts.unsafe_set(c, p + 1)
      }
    }
  }
  {
    let ends = bucket_ends()
    for i = n - 1; i >= 0; i = i - 1 {
      let j = sa.unsafe_get(i)
      if j > 0 && t.unsafe_get(j - 1) {
        let c = text.unsafe_get(j - 1)
        let p = ends.unsafe_get(c) - 1
        ends.unsafe_set(c, p)
        sa.unsafe_set(p, j - 1)
      }
    }
  }

  sa
}

///|
/// Build a suffix array for BWT using SA-IS.
/// Appends a sentinel and maps byte values to [1..256], sentinel = 0.
fn build_suffix_array(data : Bytes) -> FixedArray[Int] {
  let n = data.length()
  if n == 0 {
    return []
  }
  if n == 1 {
    return [0]
  }
  // Double the text and append sentinel for circular rotation ordering.
  // SA of data+data+sentinel, filtered to positions < n, gives the same
  // result as circular rotation sorting.
  let len = 2 * n + 1
  let text = FixedArray::make(len, 0)
  for i in 0..<n {
    let v = data[i].to_int() + 1
    text.unsafe_set(i, v)
    text.unsafe_set(n + i, v)
  }
  // text[2*n] = 0 (sentinel)
  let sa_full = sais(text, len, 257)
  // Filter: keep only positions < n (first copy)
  let sa = FixedArray::make(n, 0)
  let mut j = 0
  for i in 0..<len {
    let s = sa_full.unsafe_get(i)
    if s < n {
      sa.unsafe_set(j, s)
      j += 1
    }
  }
  sa
}
