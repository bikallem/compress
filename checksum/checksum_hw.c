/*
 * Hardware-accelerated CRC-32 (IEEE) and Adler-32.
 *
 * CRC-32: Uses PCLMULQDQ (CLMUL) for carryless multiplication folding.
 * Adler-32: Uses SSSE3 _mm_sad_epu8 for vectorized byte sums.
 *
 * Falls back to returning 0 (caller uses software path) when not available.
 *
 * Supports GCC/Clang (__attribute__((target(...))), <cpuid.h>) and
 * MSVC (__cpuid, <intrin.h>). On MSVC x64, SSSE3 and PCLMUL intrinsics
 * are always available without special compiler flags.
 */

#include <moonbit.h>
#include <stdint.h>

#if defined(__x86_64__) || defined(_M_X64) || defined(__i386__) || defined(_M_IX86)
#define HW_X86 1
#else
#define HW_X86 0
#endif

#if HW_X86
#ifdef _MSC_VER
#include <intrin.h>
#else
#include <cpuid.h>
#include <immintrin.h>
#endif
#endif

/* Per-function ISA targeting:
 * - GCC/Clang: __attribute__((target("..."))) enables specific ISA per function.
 * - MSVC x64: SSE2/SSSE3/SSE4.1/PCLMUL intrinsics are always available;
 *   no per-function attribute needed. MSVC x86 (32-bit) may need /arch:AVX
 *   but that's a build flag, not per-function. We just omit the attribute. */
#ifdef _MSC_VER
#define TARGET_PCLMUL_SSE41
#define TARGET_SSSE3
#define ALIGNED16 __declspec(align(16))
#else
#define TARGET_PCLMUL_SSE41 __attribute__((target("pclmul,sse4.1")))
#define TARGET_SSSE3        __attribute__((target("ssse3")))
#define ALIGNED16 __attribute__((aligned(16)))
#endif

/* ─── CPUID detection ─── */

static int hw_detected = 0;
static int has_pclmul = 0;
static int has_ssse3 = 0;

static void detect_hw(void) {
    if (hw_detected) return;
    hw_detected = 1;
#if HW_X86
#ifdef _MSC_VER
    int cpuinfo[4];
    __cpuid(cpuinfo, 1);
    has_pclmul = (cpuinfo[2] >> 1) & 1;   /* PCLMULQDQ */
    has_ssse3  = (cpuinfo[2] >> 9) & 1;   /* SSSE3 */
#else
    unsigned int eax, ebx, ecx, edx;
    if (__get_cpuid(1, &eax, &ebx, &ecx, &edx)) {
        has_pclmul = (ecx >> 1) & 1;   /* PCLMULQDQ */
        has_ssse3  = (ecx >> 9) & 1;   /* SSSE3 */
    }
#endif
#endif
}

/* ─── CRC-32 IEEE via CLMUL folding ─── */

/*
 * CLMUL-based IEEE CRC-32 folding.
 * Ported from chromium/zlib crc32_simd.c (widely deployed, verified).
 *
 * Fold constants are bit-reflected for the reflected IEEE polynomial.
 * Constants stored as uint64_t[2] arrays: [0]=low 64 bits, [1]=high 64 bits.
 *
 * Input: crc = running CRC state (0xFFFFFFFF for fresh computation).
 *        buf/len = data aligned to 16 bytes minimum, len >= 64.
 * Output: running CRC state (caller must XOR with ~0 to finalize).
 */

#if HW_X86

TARGET_PCLMUL_SSE41
static uint32_t crc32_clmul(uint32_t crc, const uint8_t *buf, int32_t len) {
    if (len < 64) return 0; /* too short for CLMUL, signal fallback */

    /* Aligned fold constants from chromium/zlib. */
    ALIGNED16 static const uint64_t
        k1k2[] = { 0x0154442bd4, 0x01c6e41596 };
    ALIGNED16 static const uint64_t
        k3k4[] = { 0x01751997d0, 0x00ccaa009e };
    ALIGNED16 static const uint64_t
        k5k0[] = { 0x0163cd6124, 0x0000000000 };
    ALIGNED16 static const uint64_t
        kpoly[] = { 0x01db710641, 0x01f7011641 };

    __m128i x0, x1, x2, x3, x4, x5, y5, y6, y7, y8;

    x1 = _mm_loadu_si128((const __m128i *)(buf + 0x00));
    x2 = _mm_loadu_si128((const __m128i *)(buf + 0x10));
    x3 = _mm_loadu_si128((const __m128i *)(buf + 0x20));
    x4 = _mm_loadu_si128((const __m128i *)(buf + 0x30));

    x1 = _mm_xor_si128(x1, _mm_cvtsi32_si128((int)crc));
    x0 = _mm_load_si128((const __m128i *)k1k2);

    buf += 64;
    len -= 64;

    /* Fold 64 bytes at a time */
    while (len >= 64) {
        __m128i h1 = _mm_clmulepi64_si128(x1, x0, 0x00);
        __m128i h2 = _mm_clmulepi64_si128(x2, x0, 0x00);
        __m128i h3 = _mm_clmulepi64_si128(x3, x0, 0x00);
        __m128i h4 = _mm_clmulepi64_si128(x4, x0, 0x00);

        x1 = _mm_clmulepi64_si128(x1, x0, 0x11);
        x2 = _mm_clmulepi64_si128(x2, x0, 0x11);
        x3 = _mm_clmulepi64_si128(x3, x0, 0x11);
        x4 = _mm_clmulepi64_si128(x4, x0, 0x11);

        y5 = _mm_loadu_si128((const __m128i *)(buf + 0x00));
        y6 = _mm_loadu_si128((const __m128i *)(buf + 0x10));
        y7 = _mm_loadu_si128((const __m128i *)(buf + 0x20));
        y8 = _mm_loadu_si128((const __m128i *)(buf + 0x30));

        x1 = _mm_xor_si128(_mm_xor_si128(x1, h1), y5);
        x2 = _mm_xor_si128(_mm_xor_si128(x2, h2), y6);
        x3 = _mm_xor_si128(_mm_xor_si128(x3, h3), y7);
        x4 = _mm_xor_si128(_mm_xor_si128(x4, h4), y8);

        buf += 64;
        len -= 64;
    }

    /* Fold 4 → 1 using k3k4 */
    x0 = _mm_load_si128((const __m128i *)k3k4);

    x5 = _mm_clmulepi64_si128(x1, x0, 0x00);
    x1 = _mm_clmulepi64_si128(x1, x0, 0x11);
    x1 = _mm_xor_si128(_mm_xor_si128(x1, x2), x5);

    x5 = _mm_clmulepi64_si128(x1, x0, 0x00);
    x1 = _mm_clmulepi64_si128(x1, x0, 0x11);
    x1 = _mm_xor_si128(_mm_xor_si128(x1, x3), x5);

    x5 = _mm_clmulepi64_si128(x1, x0, 0x00);
    x1 = _mm_clmulepi64_si128(x1, x0, 0x11);
    x1 = _mm_xor_si128(_mm_xor_si128(x1, x4), x5);

    /* Fold remaining 16-byte blocks */
    while (len >= 16) {
        x2 = _mm_loadu_si128((const __m128i *)buf);
        x5 = _mm_clmulepi64_si128(x1, x0, 0x00);
        x1 = _mm_clmulepi64_si128(x1, x0, 0x11);
        x1 = _mm_xor_si128(_mm_xor_si128(x1, x2), x5);
        buf += 16;
        len -= 16;
    }

    /* 128 → 64 bits */
    x2 = _mm_clmulepi64_si128(x1, x0, 0x10);
    x3 = _mm_setr_epi32(~0, 0, ~0, 0);
    x1 = _mm_xor_si128(_mm_srli_si128(x1, 8), x2);

    x0 = _mm_loadl_epi64((const __m128i *)k5k0);
    x2 = _mm_srli_si128(x1, 4);
    x1 = _mm_and_si128(x1, x3);
    x1 = _mm_clmulepi64_si128(x1, x0, 0x00);
    x1 = _mm_xor_si128(x1, x2);

    /* Barrett reduction: 64 → 32 bits */
    x0 = _mm_load_si128((const __m128i *)kpoly);
    x2 = _mm_and_si128(x1, x3);
    x2 = _mm_clmulepi64_si128(x2, x0, 0x10);
    x2 = _mm_and_si128(x2, x3);
    x2 = _mm_clmulepi64_si128(x2, x0, 0x00);
    x1 = _mm_xor_si128(x1, x2);

    uint32_t result = (uint32_t)_mm_extract_epi32(x1, 1);

    /* Process tail bytes (< 16) with software.
     * Barrett reduction returns the unfinalized CRC state, so we can
     * continue directly with the standard reflected CRC update loop. */
    if (len > 0) {
        static const uint32_t crc_table[16] = {
            0x00000000, 0x1DB71064, 0x3B6E20C8, 0x26D930AC,
            0x76DC4190, 0x6B6B51F4, 0x4DB26158, 0x5005713C,
            0xEDB88320, 0xF00F9344, 0xD6D6A3E8, 0xCB61B38C,
            0x9B64C2B0, 0x86D3D2D4, 0xA00AE278, 0xBDBDF21C,
        };
        for (int32_t i = 0; i < len; i++) {
            result ^= buf[i];
            result = (result >> 4) ^ crc_table[result & 0xF];
            result = (result >> 4) ^ crc_table[result & 0xF];
        }
    }

    return result;
}

#endif /* HW_X86 */

/* ─── Adler-32 via SSSE3 ─── */

#if HW_X86

TARGET_SSSE3
static uint32_t adler32_ssse3(uint32_t adler, const uint8_t *buf, int32_t len) {
    if (len < 32) return 0; /* too short, signal fallback */

    uint32_t s1 = adler & 0xFFFF;
    uint32_t s2 = adler >> 16;

    /*
     * For each 16-byte block, s2 receives:
     *   s2 += 16*s1 + 16*d[0] + 15*d[1] + ... + 1*d[15]
     * The coefficient vector encodes those weights.
     */
    const __m128i coeff = _mm_set_epi8(
        1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16);
    const __m128i zero = _mm_setzero_si128();
    const __m128i ones_16 = _mm_set1_epi16(1);

    while (len >= 16) {
        /* Process up to NMAX bytes before reducing mod 65521 */
        int32_t chunk = len;
        if (chunk > 5552) chunk = 5552;
        int32_t nblocks = chunk / 16;
        chunk = nblocks * 16;
        len -= chunk;

        __m128i vs1 = _mm_setzero_si128();
        __m128i vs2 = _mm_setzero_si128();
        __m128i vs1_running = _mm_setzero_si128();

        for (int32_t i = 0; i < nblocks; i++) {
            __m128i data = _mm_loadu_si128((const __m128i *)buf);
            buf += 16;

            /* Accumulate running s1 total BEFORE adding this block's bytes.
             * This tracks sum(s1_before_each_block) for s2 weighting. */
            vs1_running = _mm_add_epi32(vs1_running, vs1);

            /* Horizontal byte sum -> vs1 */
            __m128i sum = _mm_sad_epu8(data, zero);
            vs1 = _mm_add_epi32(vs1, sum);

            /* Weighted byte sum -> vs2 */
            __m128i mad = _mm_maddubs_epi16(data, coeff);
            __m128i mad32 = _mm_madd_epi16(mad, ones_16);
            vs2 = _mm_add_epi32(vs2, mad32);
        }

        /* s2 += 16 * sum(s1_before_each_block) */
        vs2 = _mm_add_epi32(vs2, _mm_slli_epi32(vs1_running, 4));

        /* Horizontal reduce vs1 (2 lanes from SAD) */
        vs1 = _mm_add_epi32(vs1, _mm_srli_si128(vs1, 8));
        uint32_t block_s1 = (uint32_t)_mm_cvtsi128_si32(vs1);

        /* Horizontal reduce vs2 (4 lanes) */
        vs2 = _mm_add_epi32(vs2, _mm_srli_si128(vs2, 8));
        vs2 = _mm_add_epi32(vs2, _mm_srli_si128(vs2, 4));
        uint32_t block_s2 = (uint32_t)_mm_cvtsi128_si32(vs2);

        /* Merge with scalar state.
         * s2 += nblocks*16*s1_scalar + block_s2 */
        s2 += (uint32_t)nblocks * 16 * s1 + block_s2;
        s1 += block_s1;

        s1 %= 65521;
        s2 %= 65521;
    }

    /* Process remaining bytes */
    for (int32_t i = 0; i < len; i++) {
        s1 += buf[i];
        s2 += s1;
    }
    s1 %= 65521;
    s2 %= 65521;

    return (s2 << 16) | s1;
}

#endif /* HW_X86 */

/* ─── Exported FFI functions ─── */

/*
 * Returns 1 if hardware CRC-32 (PCLMULQDQ) is available, 0 otherwise.
 */
MOONBIT_FFI_EXPORT
int32_t moonbit_checksum_has_hw_crc32(void) {
    detect_hw();
    return has_pclmul;
}

/*
 * Returns 1 if hardware Adler-32 (SSSE3) is available, 0 otherwise.
 */
MOONBIT_FFI_EXPORT
int32_t moonbit_checksum_has_hw_adler32(void) {
    detect_hw();
    return has_ssse3;
}

/*
 * Hardware-accelerated CRC-32 IEEE.
 * Returns the final CRC-32, or 0 if hardware not available / data too short.
 * The 'crc' parameter is the initial CRC (pre-inverted by caller).
 */
MOONBIT_FFI_EXPORT
uint32_t moonbit_crc32_hw(uint32_t crc, moonbit_bytes_t data, int32_t offset, int32_t len) {
    detect_hw();
#if HW_X86
    if (has_pclmul && len >= 64) {
        return crc32_clmul(crc, data + offset, len);
    }
#endif
    (void)crc; (void)data; (void)offset; (void)len;
    return 0;
}

/*
 * Hardware-accelerated Adler-32.
 * Returns the Adler-32, or 0 if hardware not available / data too short.
 */
MOONBIT_FFI_EXPORT
uint32_t moonbit_adler32_hw(uint32_t adler, moonbit_bytes_t data, int32_t offset, int32_t len) {
    detect_hw();
#if HW_X86
    if (has_ssse3 && len >= 32) {
        return adler32_ssse3(adler, data + offset, len);
    }
#endif
    (void)adler; (void)data; (void)offset; (void)len;
    return 0;
}
