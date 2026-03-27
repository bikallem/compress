///|
/// SA-IS: Suffix Array Induced Sorting (Nong, Zhang, Chan 2009).
/// O(n) time and space suffix array construction.
///
/// Iterative implementation to avoid stack overflow on platforms with
/// small default stack sizes (e.g. Windows 1MB).

///|
/// State saved at each level for the iterative SA-IS descent/ascent.
priv struct SaisFrame {
  text : FixedArray[Int]
  n : Int
  k : Int
  t : FixedArray[Bool]
  bkt : FixedArray[Int]
  bkt_buf : FixedArray[Int]
  sa : FixedArray[Int]
  n1 : Int
  lms_map : FixedArray[Int]
}

///|
/// Final induced sort: place sorted LMS positions from s1 into sa,
/// then induce L-type and S-type suffixes.
fn sais_final_sort(
  text : FixedArray[Int],
  n : Int,
  k : Int,
  t : FixedArray[Bool],
  bkt : FixedArray[Int],
  bkt_buf : FixedArray[Int],
  sa : FixedArray[Int],
  s1 : FixedArray[Int],
  n1 : Int,
) -> Unit {
  for i in 0..<n {
    sa.unsafe_set(i, -1)
  }
  // fill_bucket_ends
  for i = 0, sum = 0; i < k; {
    let s = sum + bkt.unsafe_get(i)
    bkt_buf.unsafe_set(i, s)
    continue i + 1, s
  }
  // Place sorted LMS right-to-left for stability.
  for i = n1 - 1; i >= 0; i = i - 1 {
    let pos = s1.unsafe_get(i)
    let c = text.unsafe_get(pos)
    let p = bkt_buf.unsafe_get(c) - 1
    bkt_buf.unsafe_set(c, p)
    sa.unsafe_set(p, pos)
  }
  // Induced sort L-type (left to right).
  // fill_bucket_starts
  for i = 0, sum = 0; i < k; {
    bkt_buf.unsafe_set(i, sum)
    continue i + 1, sum + bkt.unsafe_get(i)
  }
  for i in 0..<n {
    let j = sa.unsafe_get(i)
    if j > 0 && !t.unsafe_get(j - 1) {
      let c = text.unsafe_get(j - 1)
      let p = bkt_buf.unsafe_get(c)
      sa.unsafe_set(p, j - 1)
      bkt_buf.unsafe_set(c, p + 1)
    }
  }
  // Induced sort S-type (right to left).
  // fill_bucket_ends
  for i = 0, sum = 0; i < k; {
    let s = sum + bkt.unsafe_get(i)
    bkt_buf.unsafe_set(i, s)
    continue i + 1, s
  }
  for i = n - 1; i >= 0; i = i - 1 {
    let j = sa.unsafe_get(i)
    if j > 0 && t.unsafe_get(j - 1) {
      let c = text.unsafe_get(j - 1)
      let p = bkt_buf.unsafe_get(c) - 1
      bkt_buf.unsafe_set(c, p)
      sa.unsafe_set(p, j - 1)
    }
  }
}

///|
/// Builds a suffix array for text[0..n-1] over alphabet [0..k-1].
/// text[n-1] MUST be the unique smallest character (sentinel = 0).
fn sais(text : FixedArray[Int], n : Int, k : Int) -> FixedArray[Int] {
  let frames : Array[SaisFrame] = []
  let mut cur_text = text
  let mut cur_n = n
  let mut cur_k = k
  let mut result : FixedArray[Int] = []

  // Phase 1: Descend — reduce the problem until names are unique or n ≤ 2.
  while true {
    if cur_n == 1 {
      result = [0]
      break
    }
    if cur_n == 2 {
      // text[1] is sentinel (smallest), so SA = [1, 0]
      result = [1, 0]
      break
    }

    // Step 1: Classify suffixes as S-type (true) or L-type (false).
    let t = FixedArray::make(cur_n, false)
    t.unsafe_set(cur_n - 1, true) // sentinel is S-type
    for i = cur_n - 2; i >= 0; i = i - 1 {
      t.unsafe_set(
        i,
        if cur_text.unsafe_get(i) < cur_text.unsafe_get(i + 1) {
          true // S-type
        } else if cur_text.unsafe_get(i) > cur_text.unsafe_get(i + 1) {
          false // L-type
        } else {
          t.unsafe_get(i + 1) // same char, inherit from next
        },
      )
    }

    // Step 2: Count character frequencies for bucket computation.
    let bkt = FixedArray::make(cur_k, 0)
    for i in 0..<cur_n {
      bkt.unsafe_set(
        cur_text.unsafe_get(i),
        bkt.unsafe_get(cur_text.unsafe_get(i)) + 1,
      )
    }

    // Reusable buffer for bucket boundary computation.
    let bkt_buf = FixedArray::make(cur_k, 0)

    let sa = FixedArray::make(cur_n, -1)

    // Step 3: Place LMS suffixes at bucket ends (right-to-left for stability).
    // fill_bucket_ends
    for i = 0, sum = 0; i < cur_k; {
      let s = sum + bkt.unsafe_get(i)
      bkt_buf.unsafe_set(i, s)
      continue i + 1, s
    }
    for i = cur_n - 1; i >= 0; i = i - 1 {
      // is_lms(i): i > 0 && t[i] && !t[i-1]
      if i > 0 && t.unsafe_get(i) && !t.unsafe_get(i - 1) {
        let c = cur_text.unsafe_get(i)
        let p = bkt_buf.unsafe_get(c) - 1
        bkt_buf.unsafe_set(c, p)
        sa.unsafe_set(p, i)
      }
    }

    // Step 4: Induced sort L-type suffixes (left to right).
    // fill_bucket_starts
    for i = 0, sum = 0; i < cur_k; {
      bkt_buf.unsafe_set(i, sum)
      continue i + 1, sum + bkt.unsafe_get(i)
    }
    for i in 0..<cur_n {
      let j = sa.unsafe_get(i)
      if j > 0 && !t.unsafe_get(j - 1) {
        let c = cur_text.unsafe_get(j - 1)
        let p = bkt_buf.unsafe_get(c)
        sa.unsafe_set(p, j - 1)
        bkt_buf.unsafe_set(c, p + 1)
      }
    }

    // Step 5: Induced sort S-type suffixes (right to left).
    // fill_bucket_ends
    for i = 0, sum = 0; i < cur_k; {
      let s = sum + bkt.unsafe_get(i)
      bkt_buf.unsafe_set(i, s)
      continue i + 1, s
    }
    for i = cur_n - 1; i >= 0; i = i - 1 {
      let j = sa.unsafe_get(i)
      if j > 0 && t.unsafe_get(j - 1) {
        let c = cur_text.unsafe_get(j - 1)
        let p = bkt_buf.unsafe_get(c) - 1
        bkt_buf.unsafe_set(c, p)
        sa.unsafe_set(p, j - 1)
      }
    }

    // Step 6: Compact sorted LMS suffixes into sa[0..n1-1].
    let n1 = for i = 0, n1 = 0; i < cur_n; i = i + 1 {
      let v = sa.unsafe_get(i)
      if v > 0 && t.unsafe_get(v) && !t.unsafe_get(v - 1) {
        sa.unsafe_set(n1, v)
        continue i + 1, n1 + 1
      } else {
        continue i + 1, n1
      }
    } nobreak {
      n1
    }

    // Step 7: Name LMS substrings.
    // Use the second half of SA as workspace for names.
    for i in n1..<cur_n {
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
        for d = 0; ; d = d + 1 {
          if cur_text.unsafe_get(prev + d) != cur_text.unsafe_get(pos + d) ||
            t.unsafe_get(prev + d) != t.unsafe_get(pos + d) {
            diff = true
            break
          }
          if d > 0 {
            let lms_prev = t.unsafe_get(prev + d) && !t.unsafe_get(prev + d - 1)
            let lms_pos = t.unsafe_get(pos + d) && !t.unsafe_get(pos + d - 1)
            if lms_prev || lms_pos {
              diff = lms_prev != lms_pos
              break
            }
          }
        }
      }
      if diff {
        name += 1
      }
      prev = pos
      // Store name in the second half of SA, indexed by pos/2.
      // LMS positions are at least 2 apart (L then S), so pos/2 is unique.
      sa.unsafe_set(n1 + (pos >> 1), name - 1)
    }

    // Step 8: Collect the reduced string s1 and the LMS position map.
    let s1 = FixedArray::make(n1, 0)
    let lms_map = FixedArray::make(n1, 0)
    for i = n1, j = 0; i < cur_n; {
      if sa.unsafe_get(i) >= 0 {
        s1.unsafe_set(j, sa.unsafe_get(i))
        continue i + 1, j + 1
      }
      continue i + 1, j
    }
    // Build lms_map by scanning for LMS positions in text order.
    for i = 0, j = 0; i < cur_n; {
      if i > 0 && t.unsafe_get(i) && !t.unsafe_get(i - 1) {
        lms_map.unsafe_set(j, i)
        continue i + 1, j + 1
      }
      continue i + 1, j
    }

    // Step 9: Recurse if names are not unique.
    if name >= n1 {
      // Names are unique — directly compute the sorted order.
      let sorted = FixedArray::make(n1, 0)
      for i in 0..<n1 {
        sorted.unsafe_set(s1.unsafe_get(i), lms_map.unsafe_get(i))
      }
      // Steps 10-11: final induced sort.
      sais_final_sort(cur_text, cur_n, cur_k, t, bkt, bkt_buf, sa, sorted, n1)
      result = sa
      break
    } else {
      // Names are not unique — save frame and iterate with reduced problem.
      frames.push({
        text: cur_text,
        n: cur_n,
        k: cur_k,
        t,
        bkt,
        bkt_buf,
        sa,
        n1,
        lms_map,
      })
      cur_text = s1
      cur_n = n1
      cur_k = name
    }
  }

  // Phase 2: Ascend — propagate solutions back through saved frames.
  for i = frames.length() - 1; i >= 0; i = i - 1 {
    let frame = frames[i]
    let sa1 = result
    // Map back: sa1[i] is an index into the reduced string.
    // lms_map[sa1[i]] gives the original text position.
    let s1 = FixedArray::make(frame.n1, 0)
    for j in 0..<frame.n1 {
      s1.unsafe_set(j, frame.lms_map.unsafe_get(sa1.unsafe_get(j)))
    }
    // Steps 10-11: final induced sort for this level.
    sais_final_sort(
      frame.text,
      frame.n,
      frame.k,
      frame.t,
      frame.bkt,
      frame.bkt_buf,
      frame.sa,
      s1,
      frame.n1,
    )
    result = frame.sa
  }

  result
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
    let v = data.unsafe_get(i).to_int() + 1
    text.unsafe_set(i, v)
    text.unsafe_set(n + i, v)
  }
  // text[2*n] = 0 (sentinel)
  let sa_full = sais(text, len, 257)
  // Filter: keep only positions < n (first copy)
  let sa = FixedArray::make(n, 0)
  for i = 0, j = 0; i < len; {
    let s = sa_full.unsafe_get(i)
    if s < n {
      sa.unsafe_set(j, s)
      continue i + 1, j + 1
    }
    continue i + 1, j
  }
  sa
}
