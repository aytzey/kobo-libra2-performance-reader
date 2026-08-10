/*
    KOReader: blitbuffer implementation for jit-disabled platforms
    Copyright (C) 2011 Hans-Werner Hilse <hilse@web.de>
                  2017 Huang Xin <chrox.huang@gmail.com>

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <http://www.gnu.org/licenses/>.
*/

#include <stdio.h>
#include <stdlib.h>
#include <stdbool.h>
#include <string.h>
#include "blitbuffer.h"

#if defined(__ARM_NEON) || defined(__ARM_NEON__)
#include <arm_neon.h>
#define BB_HAS_ARM_NEON 1
#else
#define BB_HAS_ARM_NEON 0
#endif

static const char*
    get_bbtype_name(int bbtype)
{
    switch (bbtype) {
        case TYPE_BB4:
            return "BB4";
        case TYPE_BB8:
            return "BB8";
        case TYPE_BB8A:
            return "BB8A";
        case TYPE_BBRGB16:
            return "BBRGB16";
        case TYPE_BBRGB24:
            return "BBRGB24";
        case TYPE_BBRGB32:
            return "BBRGB32";
        default:
            return "Unknown!";
    }
}

#define ColorRGB32_To_Color8(color) \
    (Color8){(4898U*color->r + 9618U*color->g + 1869U*color->b) >> 14U}
#define ColorRGB32_To_Color8A(color) \
    (Color8A){(4898U*color->r + 9618U*color->g + 1869U*color->b) >> 14U, color->alpha}
#define ColorRGB32_To_Color16(color) \
    (ColorRGB16){((color->r & 0xF8) << 8U) + ((color->g & 0xFC) << 3U) + ((color->b >> 3U))}
#define ColorRGB32_To_Color24(color) \
    (ColorRGB24){color->r, color->g, color->b}

#define Color8_To_Color8A(color) \
    (Color8A){color->a, 0xFF}
#define Color8A_To_Color8(color) \
    (Color8){color->a}
#define Color8A_To_Color24(color) \
    (ColorRGB24){color->a, color->a, color->a}
#define Color8A_To_Color16(color) \
    (ColorRGB16){((color->a & 0xF8) << 8U) + ((color->a & 0xFC) << 3U) + ((color->a >> 3U))}
#define Color8A_To_Color32(color) \
    (ColorRGB32){color->a, color->a, color->a, color->alpha}

#define ColorRGB16_GetR(v) (((v >> 11U) << 3U) + ((v >> 11U) >> 2U))
#define ColorRGB16_GetG(v) ((((v >> 5U) & 0x3F) << 2U) + (((v >> 5U) & 0x3F) >> 4U))
#define ColorRGB16_GetB(v) (((v & 0x001F) << 3U) + ((v & 0x001F) >> 2U))
#define ColorRGB16_To_A(v) \
    ((39919*ColorRGB16_GetR(v) + \
      39185*ColorRGB16_GetG(v) + \
      15220*ColorRGB16_GetB(v)) >> 14U)
#define RGB_To_RGB16(r, g, b) (((r & 0xF8) << 8U) + ((g & 0xFC) << 3U) + (b >> 3U))
// NOTE: `A` was a *terrible* variable name to settle on. It's actually luminance, e.g., grayscale, a.k.a., Y8.
#define RGB_To_A(r, g, b) ((4898U*r + 9618U*g + 1869U*b) >> 14U)

// Helpers to pack pixels manually, without going through the Color structs.
#define Y8_To_Y8A(v) (0xFFu << 8U | v)
#define RGB_To_RGB32(r, g, b) ((uint32_t) (0xFFu << 24U) | (uint32_t) (b << 16U) | (uint32_t) (g << 8U) | r)
#define Y8_To_RGB32(v) ((uint32_t) (0xFFu << 24U) | (uint32_t) (v << 16U) | (uint32_t) (v << 8U) | v)
#define Y8A_To_RGB32(v, alpha) ((uint32_t) ((uint32_t) (alpha) << 24U) | (uint32_t) ((v) << 16U) | (uint32_t) ((v) << 8U) | (v))

// __auto_type was introduced in GCC 4.9 (and Clang ~3.8)...
// NOTE: Inspired from glibc's __GNUC_PREREQ && __glibc_clang_prereq macros (from <features.h>),
//       which we of course can't use because some of our TCs use a glibc version old enough not to have the clang one...
#if (defined(__clang__) && (__clang_major__ > 3 || (__clang_major__ == 3 && __clang_minor__ >= 8))) || \
    ((defined(__GNUC__) && !defined(__clang__)) && (__GNUC__ > 4 || (__GNUC__ == 4 && __GNUC_MINOR__ >= 9)))
//#warning "Auto Type :)"

#define DIV_255(V)                                                                                   \
({                                                                                                   \
    __auto_type _v = (V) + 128;                                                                      \
    (((_v >> 8U) + _v) >> 8U);                                                                       \
})

#define ColorRGB32_To_PMUL(color) \
    (ColorRGB32){DIV_255(color->r * color->alpha), DIV_255(color->g * color->alpha), DIV_255(color->b * color->alpha), color->alpha}

// MIN/MAX with no side-effects,
// c.f., https://gcc.gnu.org/onlinedocs/cpp/Duplication-of-Side-Effects.html#Duplication-of-Side-Effects
//     & https://dustri.org/b/min-and-max-macro-considered-harmful.html
#define MIN(X, Y)                                                                                    \
({                                                                                                   \
    __auto_type x_ = (X);                                                                            \
    __auto_type y_ = (Y);                                                                            \
    (x_ < y_) ? x_ : y_;                                                                             \
})

#define MAX(X, Y)                                                                                    \
({                                                                                                   \
    __auto_type x__ = (X);                                                                           \
    __auto_type y__ = (Y);                                                                           \
    (x__ > y__) ? x__ : y__;                                                                         \
})

#else
#warning "TypeOf :("

#define DIV_255(V)                                                                                   \
({                                                                                                   \
    typeof (V) _v = (V) + 128;                                                                       \
    (((_v >> 8U) + _v) >> 8U);                                                                       \
})

#define MIN(X, Y)                                                                                    \
({                                                                                                   \
    typeof (X) x_ = (X);                                                                             \
    typeof (Y) y_ = (Y);                                                                             \
    (x_ < y_) ? x_ : y_;                                                                             \
})

#define MAX(X, Y)                                                                                    \
({                                                                                                   \
    typeof (X) x__ = (X);                                                                            \
    typeof (Y) y__ = (Y);                                                                            \
    (x__ > y__) ? x__ : y__;                                                                         \
})

#endif

// Likely/Unlikely branch tagging
#define likely(x)   __builtin_expect(!!(x), 1)
#define unlikely(x) __builtin_expect(!!(x), 0)

#if defined(__arm__) && (defined(__ARM_ARCH_7__) || defined(__ARM_ARCH_7A__) || defined(__ARM_ARCH_7R__) || defined(__ARM_ARCH_7M__) || defined(__ARM_ARCH_7EM__))
#define BB_PREFETCH_READ(ptr) __asm__ __volatile__("pld [%0]" :: "r" (ptr) : "memory")
#else
#define BB_PREFETCH_READ(ptr) __builtin_prefetch((ptr), 0, 1)
#endif
#define BB_PREFETCH_WRITE(ptr) __builtin_prefetch((ptr), 1, 1)

static inline void
    BB_copy_rows(uint8_t * restrict dst, size_t dst_stride,
                 const uint8_t * restrict src, size_t src_stride,
                 size_t row_bytes, unsigned int h)
{
    if (unlikely(row_bytes == 0 || h == 0)) {
        return;
    }
    if (likely(dst_stride == row_bytes && src_stride == row_bytes)) {
        memcpy(dst, src, row_bytes * (size_t) h);
        return;
    }
    for (unsigned int y = 0; y < h; y++) {
        memcpy(dst, src, row_bytes);
        src += src_stride;
        dst += dst_stride;
    }
}

static inline uint8_t
    BB_rgb32_to_y8(const ColorRGB32 * restrict src)
{
    return (uint8_t) RGB_To_A(src->r, src->g, src->b);
}

#if BB_HAS_ARM_NEON
static inline uint8x8_t
    BB_rgb32_luma8_neon(const ColorRGB32 * restrict src)
{
    const uint8x8x4_t rgba = vld4_u8((const uint8_t *) src);
    const uint16x8_t r16 = vmovl_u8(rgba.val[0]);
    const uint16x8_t g16 = vmovl_u8(rgba.val[1]);
    const uint16x8_t b16 = vmovl_u8(rgba.val[2]);

    uint32x4_t y0 = vmull_n_u16(vget_low_u16(r16), 4898U);
    y0 = vmlal_n_u16(y0, vget_low_u16(g16), 9618U);
    y0 = vmlal_n_u16(y0, vget_low_u16(b16), 1869U);

    uint32x4_t y1 = vmull_n_u16(vget_high_u16(r16), 4898U);
    y1 = vmlal_n_u16(y1, vget_high_u16(g16), 9618U);
    y1 = vmlal_n_u16(y1, vget_high_u16(b16), 1869U);

    const uint16x8_t y16 = vcombine_u16(vshrn_n_u32(y0, 14), vshrn_n_u32(y1, 14));
    return vmovn_u16(y16);
}

static inline unsigned int
    BB_rgb32_to_bb8_row_neon(Color8 * restrict dst, const ColorRGB32 * restrict src, unsigned int w)
{
    unsigned int x = 0;
    for (; x + 8U <= w; x += 8U) {
        BB_PREFETCH_READ(src + x + 32U);
        BB_PREFETCH_WRITE(dst + x + 32U);
        vst1_u8((uint8_t *) (dst + x), BB_rgb32_luma8_neon(src + x));
    }
    return x;
}
#endif

static inline void
    BB_rgb32_to_bb8_row(Color8 * restrict dst, const ColorRGB32 * restrict src, unsigned int w)
{
    unsigned int x = 0;
#if BB_HAS_ARM_NEON
    x = BB_rgb32_to_bb8_row_neon(dst, src, w);
#endif
    for (; x + 4U <= w; x += 4U) {
        BB_PREFETCH_READ(src + x + 32U);
        BB_PREFETCH_WRITE(dst + x + 32U);
        dst[x].a = BB_rgb32_to_y8(src + x);
        dst[x + 1U].a = BB_rgb32_to_y8(src + x + 1U);
        dst[x + 2U].a = BB_rgb32_to_y8(src + x + 2U);
        dst[x + 3U].a = BB_rgb32_to_y8(src + x + 3U);
    }
    for (; x < w; x++) {
        dst[x].a = BB_rgb32_to_y8(src + x);
    }
}

#if BB_HAS_ARM_NEON
static inline uint8x8_t
    BB_div255_u16_to_u8_neon(uint16x8_t v)
{
    const uint16x8_t t = vaddq_u16(v, vdupq_n_u16(128U));
    return vmovn_u16(vshrq_n_u16(vaddq_u16(t, vshrq_n_u16(t, 8)), 8));
}

static inline unsigned int
    BB_blend_y8_row_neon(uint8_t * restrict dst, unsigned int w, uint8_t src, uint8_t alpha)
{
    unsigned int x = 0;
    const uint8x8_t src8 = vdup_n_u8(src);
    const uint8x8_t alpha8 = vdup_n_u8(alpha);
    const uint8x8_t ainv8 = vdup_n_u8(alpha ^ 0xFFU);
    for (; x + 16U <= w; x += 16U) {
        BB_PREFETCH_WRITE(dst + x + 64U);
        const uint8x16_t d = vld1q_u8(dst + x);

        uint16x8_t lo = vmull_u8(vget_low_u8(d), ainv8);
        lo = vmlal_u8(lo, src8, alpha8);
        uint16x8_t hi = vmull_u8(vget_high_u8(d), ainv8);
        hi = vmlal_u8(hi, src8, alpha8);

        vst1q_u8(dst + x, vcombine_u8(BB_div255_u16_to_u8_neon(lo), BB_div255_u16_to_u8_neon(hi)));
    }
    return x;
}

static inline unsigned int
    BB_multiply_y8_row_neon(uint8_t * restrict dst, unsigned int w, uint8_t src)
{
    unsigned int x = 0;
    const uint8x8_t src8 = vdup_n_u8(src);
    for (; x + 16U <= w; x += 16U) {
        BB_PREFETCH_WRITE(dst + x + 64U);
        const uint8x16_t d = vld1q_u8(dst + x);
        const uint16x8_t lo = vmull_u8(vget_low_u8(d), src8);
        const uint16x8_t hi = vmull_u8(vget_high_u8(d), src8);
        vst1q_u8(dst + x, vcombine_u8(BB_div255_u16_to_u8_neon(lo), BB_div255_u16_to_u8_neon(hi)));
    }
    return x;
}

static inline unsigned int
    BB_multiply_over_y8_row_neon(uint8_t * restrict dst, unsigned int w, uint8_t src, uint8_t alpha)
{
    unsigned int x = 0;
    const uint8x8_t src8 = vdup_n_u8(src);
    const uint8x8_t alpha8 = vdup_n_u8(alpha);
    const uint8x8_t ainv8 = vdup_n_u8(alpha ^ 0xFFU);
    for (; x + 16U <= w; x += 16U) {
        BB_PREFETCH_WRITE(dst + x + 64U);
        const uint8x16_t d = vld1q_u8(dst + x);
        const uint8x8_t dlo = vget_low_u8(d);
        const uint8x8_t dhi = vget_high_u8(d);
        const uint8x8_t mlo = BB_div255_u16_to_u8_neon(vmull_u8(dlo, src8));
        const uint8x8_t mhi = BB_div255_u16_to_u8_neon(vmull_u8(dhi, src8));

        uint16x8_t lo = vmull_u8(dlo, ainv8);
        lo = vmlal_u8(lo, mlo, alpha8);
        uint16x8_t hi = vmull_u8(dhi, ainv8);
        hi = vmlal_u8(hi, mhi, alpha8);

        vst1q_u8(dst + x, vcombine_u8(BB_div255_u16_to_u8_neon(lo), BB_div255_u16_to_u8_neon(hi)));
    }
    return x;
}

static inline unsigned int
    BB_set_y8a_luma_row_neon(Color8A * restrict dst, unsigned int w, uint8_t src)
{
    unsigned int x = 0;
    const uint8x8_t src8 = vdup_n_u8(src);
    for (; x + 8U <= w; x += 8U) {
        BB_PREFETCH_WRITE(dst + x + 32U);
        uint8x8x2_t ya = vld2_u8((uint8_t *) (dst + x));
        ya.val[0] = src8;
        vst2_u8((uint8_t *) (dst + x), ya);
    }
    return x;
}

static inline unsigned int
    BB_blend_y8a_luma_row_neon(Color8A * restrict dst, unsigned int w, uint8_t src, uint8_t alpha)
{
    unsigned int x = 0;
    const uint8x8_t src8 = vdup_n_u8(src);
    const uint8x8_t alpha8 = vdup_n_u8(alpha);
    const uint8x8_t ainv8 = vdup_n_u8(alpha ^ 0xFFU);
    for (; x + 8U <= w; x += 8U) {
        BB_PREFETCH_WRITE(dst + x + 32U);
        uint8x8x2_t ya = vld2_u8((uint8_t *) (dst + x));
        uint16x8_t acc = vmull_u8(ya.val[0], ainv8);
        acc = vmlal_u8(acc, src8, alpha8);
        ya.val[0] = BB_div255_u16_to_u8_neon(acc);
        vst2_u8((uint8_t *) (dst + x), ya);
    }
    return x;
}

static inline unsigned int
    BB_multiply_y8a_luma_row_neon(Color8A * restrict dst, unsigned int w, uint8_t src)
{
    unsigned int x = 0;
    const uint8x8_t src8 = vdup_n_u8(src);
    for (; x + 8U <= w; x += 8U) {
        BB_PREFETCH_WRITE(dst + x + 32U);
        uint8x8x2_t ya = vld2_u8((uint8_t *) (dst + x));
        ya.val[0] = BB_div255_u16_to_u8_neon(vmull_u8(ya.val[0], src8));
        vst2_u8((uint8_t *) (dst + x), ya);
    }
    return x;
}

static inline unsigned int
    BB_multiply_over_y8a_luma_row_neon(Color8A * restrict dst, unsigned int w, uint8_t src, uint8_t alpha)
{
    unsigned int x = 0;
    const uint8x8_t src8 = vdup_n_u8(src);
    const uint8x8_t alpha8 = vdup_n_u8(alpha);
    const uint8x8_t ainv8 = vdup_n_u8(alpha ^ 0xFFU);
    for (; x + 8U <= w; x += 8U) {
        BB_PREFETCH_WRITE(dst + x + 32U);
        uint8x8x2_t ya = vld2_u8((uint8_t *) (dst + x));
        const uint8x8_t multiplied = BB_div255_u16_to_u8_neon(vmull_u8(ya.val[0], src8));
        uint16x8_t acc = vmull_u8(ya.val[0], ainv8);
        acc = vmlal_u8(acc, multiplied, alpha8);
        ya.val[0] = BB_div255_u16_to_u8_neon(acc);
        vst2_u8((uint8_t *) (dst + x), ya);
    }
    return x;
}

static inline unsigned int
    BB_rgb32_alpha_to_bb8_row_neon(Color8 * restrict dst, const ColorRGB32 * restrict src, unsigned int w)
{
    unsigned int x = 0;
    for (; x + 8U <= w; x += 8U) {
        BB_PREFETCH_READ(src + x + 32U);
        BB_PREFETCH_WRITE(dst + x + 32U);
        const uint8x8x4_t rgba = vld4_u8((const uint8_t *) (src + x));
        const uint16x8_t r16 = vmovl_u8(rgba.val[0]);
        const uint16x8_t g16 = vmovl_u8(rgba.val[1]);
        const uint16x8_t b16 = vmovl_u8(rgba.val[2]);

        uint32x4_t y0 = vmull_n_u16(vget_low_u16(r16), 4898U);
        y0 = vmlal_n_u16(y0, vget_low_u16(g16), 9618U);
        y0 = vmlal_n_u16(y0, vget_low_u16(b16), 1869U);

        uint32x4_t y1 = vmull_n_u16(vget_high_u16(r16), 4898U);
        y1 = vmlal_n_u16(y1, vget_high_u16(g16), 9618U);
        y1 = vmlal_n_u16(y1, vget_high_u16(b16), 1869U);

        const uint16x8_t y16 = vcombine_u16(vshrn_n_u32(y0, 14), vshrn_n_u32(y1, 14));
        const uint8x8_t y8 = vmovn_u16(y16);
        const uint8x8_t d = vld1_u8((const uint8_t *) (dst + x));
        uint16x8_t acc = vmull_u8(d, vmvn_u8(rgba.val[3]));
        acc = vmlal_u8(acc, y8, rgba.val[3]);
        vst1_u8((uint8_t *) (dst + x), BB_div255_u16_to_u8_neon(acc));
    }
    return x;
}

static inline unsigned int
    BB_bb8a_alpha_to_bb8_row_neon(Color8 * restrict dst, const Color8A * restrict src, unsigned int w)
{
    unsigned int x = 0;
    for (; x + 8U <= w; x += 8U) {
        BB_PREFETCH_READ(src + x + 32U);
        BB_PREFETCH_WRITE(dst + x + 32U);
        const uint8x8x2_t ya = vld2_u8((const uint8_t *) (src + x));
        const uint8x8_t d = vld1_u8((const uint8_t *) (dst + x));
        uint16x8_t acc = vmull_u8(d, vmvn_u8(ya.val[1]));
        acc = vmlal_u8(acc, ya.val[0], ya.val[1]);
        vst1_u8((uint8_t *) (dst + x), BB_div255_u16_to_u8_neon(acc));
    }
    return x;
}
#endif

static inline void
    BB_rgb32_alpha_to_bb8_row(Color8 * restrict dst, const ColorRGB32 * restrict src, unsigned int w)
{
    unsigned int x = 0;
#if BB_HAS_ARM_NEON
    x = BB_rgb32_alpha_to_bb8_row_neon(dst, src, w);
#endif
    for (; x < w; x++) {
        if ((x & 31U) == 0) {
            BB_PREFETCH_READ(src + x + 32U);
            BB_PREFETCH_WRITE(dst + x + 32U);
        }
        const uint8_t alpha = src[x].alpha;
        if (alpha == 0) {
            continue;
        }
        const uint8_t srca = BB_rgb32_to_y8(src + x);
        if (alpha == 0xFF) {
            dst[x].a = srca;
        } else {
            const uint8_t ainv = alpha ^ 0xFF;
            dst[x].a = (uint8_t) DIV_255(dst[x].a * ainv + srca * alpha);
        }
    }
}

static inline void
    BB_bb8a_alpha_to_bb8_row(Color8 * restrict dst, const Color8A * restrict src, unsigned int w)
{
    unsigned int x = 0;
#if BB_HAS_ARM_NEON
    x = BB_bb8a_alpha_to_bb8_row_neon(dst, src, w);
#endif
    for (; x < w; x++) {
        const uint8_t alpha = src[x].alpha;
        if (alpha == 0) {
            continue;
        }
        if (alpha == 0xFF) {
            dst[x].a = src[x].a;
        } else {
            const uint8_t ainv = alpha ^ 0xFF;
            dst[x].a = (uint8_t) DIV_255(dst[x].a * ainv + src[x].a * alpha);
        }
    }
}

static inline void
    BB_bb8a_pmulalpha_to_bb8_row(Color8 * restrict dst, const Color8A * restrict src, unsigned int w)
{
    for (unsigned int x = 0; x < w; x++) {
        const uint8_t alpha = src[x].alpha;
        if (alpha == 0) {
            continue;
        }
        if (alpha == 0xFF) {
            dst[x].a = src[x].a;
        } else {
            const uint8_t ainv = alpha ^ 0xFF;
            dst[x].a = (uint8_t) DIV_255(dst[x].a * ainv + src[x].a * 0xFF);
        }
    }
}

static inline void
    BB_rgb32_pmulalpha_to_bb8_row(Color8 * restrict dst, const ColorRGB32 * restrict src, unsigned int w)
{
    for (unsigned int x = 0; x < w; x++) {
        const uint8_t alpha = src[x].alpha;
        if (alpha == 0) {
            continue;
        }
        const uint8_t srca = BB_rgb32_to_y8(src + x);
        if (alpha == 0xFF) {
            dst[x].a = srca;
        } else {
            const uint8_t ainv = alpha ^ 0xFF;
            dst[x].a = (uint8_t) DIV_255(dst[x].a * ainv + srca * 0xFF);
        }
    }
}

static inline void
    BB_dither_y8_to_bb8_row(Color8 * restrict dst, const Color8 * restrict src, unsigned int w,
                            unsigned int row_phase, unsigned int col_phase,
                            const uint8_t (* restrict dither_lut)[256])
{
    for (unsigned int x = 0; x < w; x++) {
        dst[x].a = dither_lut[row_phase + col_phase][src[x].a];
        col_phase = (col_phase + 1U) & 7U;
    }
}

static inline void
    BB_dither_alpha_y8a_to_bb8_row(Color8 * restrict dst, const Color8A * restrict src, unsigned int w,
                                   unsigned int row_phase, unsigned int col_phase,
                                   const uint8_t (* restrict dither_lut)[256])
{
    for (unsigned int x = 0; x < w; x++) {
        const uint8_t alpha = src[x].alpha;
        if (alpha != 0) {
            uint8_t v;
            if (alpha == 0xFF) {
                v = src[x].a;
            } else {
                const uint8_t ainv = alpha ^ 0xFF;
                v = (uint8_t) DIV_255(dst[x].a * ainv + src[x].a * alpha);
            }
            dst[x].a = dither_lut[row_phase + col_phase][v];
        }
        col_phase = (col_phase + 1U) & 7U;
    }
}

static inline void
    BB_dither_pmulalpha_y8a_to_bb8_row(Color8 * restrict dst, const Color8A * restrict src, unsigned int w,
                                       unsigned int row_phase, unsigned int col_phase,
                                       const uint8_t (* restrict dither_lut)[256])
{
    for (unsigned int x = 0; x < w; x++) {
        const uint8_t alpha = src[x].alpha;
        if (alpha != 0) {
            uint8_t v;
            if (alpha == 0xFF) {
                v = src[x].a;
            } else {
                const uint8_t ainv = alpha ^ 0xFF;
                v = (uint8_t) DIV_255(dst[x].a * ainv + src[x].a * 0xFF);
            }
            dst[x].a = dither_lut[row_phase + col_phase][v];
        }
        col_phase = (col_phase + 1U) & 7U;
    }
}

static inline void
    BB_dither_alpha_rgb32_to_bb8_row(Color8 * restrict dst, const ColorRGB32 * restrict src, unsigned int w,
                                     unsigned int row_phase, unsigned int col_phase,
                                     const uint8_t (* restrict dither_lut)[256])
{
    for (unsigned int x = 0; x < w; x++) {
        const uint8_t alpha = src[x].alpha;
        if (alpha != 0) {
            const uint8_t srca = BB_rgb32_to_y8(src + x);
            uint8_t v;
            if (alpha == 0xFF) {
                v = srca;
            } else {
                const uint8_t ainv = alpha ^ 0xFF;
                v = (uint8_t) DIV_255(dst[x].a * ainv + srca * alpha);
            }
            dst[x].a = dither_lut[row_phase + col_phase][v];
        }
        col_phase = (col_phase + 1U) & 7U;
    }
}

static inline void
    BB_dither_pmulalpha_rgb32_to_bb8_row(Color8 * restrict dst, const ColorRGB32 * restrict src, unsigned int w,
                                         unsigned int row_phase, unsigned int col_phase,
                                         const uint8_t (* restrict dither_lut)[256])
{
    for (unsigned int x = 0; x < w; x++) {
        const uint8_t alpha = src[x].alpha;
        if (alpha != 0) {
            const uint8_t srca = BB_rgb32_to_y8(src + x);
            uint8_t v;
            if (alpha == 0xFF) {
                v = srca;
            } else {
                const uint8_t ainv = alpha ^ 0xFF;
                v = (uint8_t) DIV_255(dst[x].a * ainv + srca * 0xFF);
            }
            dst[x].a = dither_lut[row_phase + col_phase][v];
        }
        col_phase = (col_phase + 1U) & 7U;
    }
}

static inline void
    BB_dither_rgb32_to_bb8_row(Color8 * restrict dst, const ColorRGB32 * restrict src,
                               unsigned int w, unsigned int row_phase, unsigned int col_phase,
                               const uint8_t (* restrict dither_lut)[256])
{
    unsigned int x = 0;
#if BB_HAS_ARM_NEON
    const uint8_t * restrict lut0 = dither_lut[row_phase + ((col_phase + 0U) & 7U)];
    const uint8_t * restrict lut1 = dither_lut[row_phase + ((col_phase + 1U) & 7U)];
    const uint8_t * restrict lut2 = dither_lut[row_phase + ((col_phase + 2U) & 7U)];
    const uint8_t * restrict lut3 = dither_lut[row_phase + ((col_phase + 3U) & 7U)];
    const uint8_t * restrict lut4 = dither_lut[row_phase + ((col_phase + 4U) & 7U)];
    const uint8_t * restrict lut5 = dither_lut[row_phase + ((col_phase + 5U) & 7U)];
    const uint8_t * restrict lut6 = dither_lut[row_phase + ((col_phase + 6U) & 7U)];
    const uint8_t * restrict lut7 = dither_lut[row_phase + ((col_phase + 7U) & 7U)];
    for (; x + 8U <= w; x += 8U) {
        BB_PREFETCH_READ(src + x + 32U);
        BB_PREFETCH_WRITE(dst + x + 32U);
        uint8_t y[8];
        vst1_u8(y, BB_rgb32_luma8_neon(src + x));
        dst[x].a = lut0[y[0]];
        dst[x + 1U].a = lut1[y[1]];
        dst[x + 2U].a = lut2[y[2]];
        dst[x + 3U].a = lut3[y[3]];
        dst[x + 4U].a = lut4[y[4]];
        dst[x + 5U].a = lut5[y[5]];
        dst[x + 6U].a = lut6[y[6]];
        dst[x + 7U].a = lut7[y[7]];
    }
#endif
    for (; x + 8U <= w; x += 8U) {
        BB_PREFETCH_READ(src + x + 32U);
        BB_PREFETCH_WRITE(dst + x + 32U);
        dst[x].a = dither_lut[row_phase + ((col_phase + 0U) & 7U)][BB_rgb32_to_y8(src + x)];
        dst[x + 1U].a = dither_lut[row_phase + ((col_phase + 1U) & 7U)][BB_rgb32_to_y8(src + x + 1U)];
        dst[x + 2U].a = dither_lut[row_phase + ((col_phase + 2U) & 7U)][BB_rgb32_to_y8(src + x + 2U)];
        dst[x + 3U].a = dither_lut[row_phase + ((col_phase + 3U) & 7U)][BB_rgb32_to_y8(src + x + 3U)];
        dst[x + 4U].a = dither_lut[row_phase + ((col_phase + 4U) & 7U)][BB_rgb32_to_y8(src + x + 4U)];
        dst[x + 5U].a = dither_lut[row_phase + ((col_phase + 5U) & 7U)][BB_rgb32_to_y8(src + x + 5U)];
        dst[x + 6U].a = dither_lut[row_phase + ((col_phase + 6U) & 7U)][BB_rgb32_to_y8(src + x + 6U)];
        dst[x + 7U].a = dither_lut[row_phase + ((col_phase + 7U) & 7U)][BB_rgb32_to_y8(src + x + 7U)];
        col_phase = (col_phase + 8U) & 7U;
    }
    for (; x < w; x++) {
        dst[x].a = dither_lut[row_phase + col_phase][BB_rgb32_to_y8(src + x)];
        col_phase = (col_phase + 1U) & 7U;
    }
}

#if BB_HAS_ARM_NEON
static inline unsigned int
    BB_y8_to_rgb32_row_neon(uint32_t * restrict dst, const Color8 * restrict src, unsigned int w)
{
    unsigned int x = 0;
    const uint8x8_t opaque = vdup_n_u8(0xFF);
    for (; x + 8U <= w; x += 8U) {
        BB_PREFETCH_READ(src + x + 32U);
        BB_PREFETCH_WRITE(dst + x + 32U);
        const uint8x8_t y = vld1_u8((const uint8_t *) (src + x));
        const uint8x8x4_t rgba = { { y, y, y, opaque } };
        vst4_u8((uint8_t *) (dst + x), rgba);
    }
    return x;
}

static inline unsigned int
    BB_y8a_to_rgb32_row_neon(uint32_t * restrict dst, const Color8A * restrict src, unsigned int w)
{
    unsigned int x = 0;
    for (; x + 8U <= w; x += 8U) {
        BB_PREFETCH_READ(src + x + 32U);
        BB_PREFETCH_WRITE(dst + x + 32U);
        const uint8x8x2_t ya = vld2_u8((const uint8_t *) (src + x));
        const uint8x8x4_t rgba = { { ya.val[0], ya.val[0], ya.val[0], ya.val[1] } };
        vst4_u8((uint8_t *) (dst + x), rgba);
    }
    return x;
}
#endif

static inline void
    BB_y8_to_rgb32_row(uint32_t * restrict dst, const Color8 * restrict src, unsigned int w)
{
    unsigned int x = 0;
#if BB_HAS_ARM_NEON
    x = BB_y8_to_rgb32_row_neon(dst, src, w);
#endif
    for (; x + 4U <= w; x += 4U) {
        BB_PREFETCH_READ(src + x + 32U);
        BB_PREFETCH_WRITE(dst + x + 32U);
        dst[x] = (uint32_t) Y8_To_RGB32(src[x].a);
        dst[x + 1U] = (uint32_t) Y8_To_RGB32(src[x + 1U].a);
        dst[x + 2U] = (uint32_t) Y8_To_RGB32(src[x + 2U].a);
        dst[x + 3U] = (uint32_t) Y8_To_RGB32(src[x + 3U].a);
    }
    for (; x < w; x++) {
        dst[x] = (uint32_t) Y8_To_RGB32(src[x].a);
    }
}

static inline void
    BB_y8a_to_rgb32_row(uint32_t * restrict dst, const Color8A * restrict src, unsigned int w)
{
    unsigned int x = 0;
#if BB_HAS_ARM_NEON
    x = BB_y8a_to_rgb32_row_neon(dst, src, w);
#endif
    for (; x + 4U <= w; x += 4U) {
        BB_PREFETCH_READ(src + x + 32U);
        BB_PREFETCH_WRITE(dst + x + 32U);
        dst[x] = (uint32_t) Y8A_To_RGB32(src[x].a, src[x].alpha);
        dst[x + 1U] = (uint32_t) Y8A_To_RGB32(src[x + 1U].a, src[x + 1U].alpha);
        dst[x + 2U] = (uint32_t) Y8A_To_RGB32(src[x + 2U].a, src[x + 2U].alpha);
        dst[x + 3U] = (uint32_t) Y8A_To_RGB32(src[x + 3U].a, src[x + 3U].alpha);
    }
    for (; x < w; x++) {
        dst[x] = (uint32_t) Y8A_To_RGB32(src[x].a, src[x].alpha);
    }
}

static inline void
    BB_blend_y8_row(uint8_t * restrict dst, unsigned int w, uint8_t src, uint8_t alpha)
{
    if (unlikely(w == 0 || alpha == 0)) {
        return;
    }
    if (alpha == 0xFF) {
        memset(dst, src, w);
        return;
    }

    const uint8_t ainv = alpha ^ 0xFF;
    unsigned int x = 0;
#if BB_HAS_ARM_NEON
    x = BB_blend_y8_row_neon(dst, w, src, alpha);
#endif
    for (; x + 4U <= w; x += 4U) {
        BB_PREFETCH_WRITE(dst + x + 32U);
        dst[x]      = (uint8_t) DIV_255(dst[x]      * ainv + src * alpha);
        dst[x + 1U] = (uint8_t) DIV_255(dst[x + 1U] * ainv + src * alpha);
        dst[x + 2U] = (uint8_t) DIV_255(dst[x + 2U] * ainv + src * alpha);
        dst[x + 3U] = (uint8_t) DIV_255(dst[x + 3U] * ainv + src * alpha);
    }
    for (; x < w; x++) {
        dst[x] = (uint8_t) DIV_255(dst[x] * ainv + src * alpha);
    }
}

static inline void
    BB_blend_y8a_luma_row(Color8A * restrict dst, unsigned int w, uint8_t src, uint8_t alpha)
{
    if (unlikely(w == 0 || alpha == 0)) {
        return;
    }
    if (alpha == 0xFF) {
        unsigned int x = 0;
#if BB_HAS_ARM_NEON
        x = BB_set_y8a_luma_row_neon(dst, w, src);
#endif
        for (; x < w; x++) {
            dst[x].a = src;
        }
        return;
    }

    const uint8_t ainv = alpha ^ 0xFF;
    unsigned int x = 0;
#if BB_HAS_ARM_NEON
    x = BB_blend_y8a_luma_row_neon(dst, w, src, alpha);
#endif
    for (; x < w; x++) {
        if ((x & 31U) == 0) {
            BB_PREFETCH_WRITE(dst + x + 32U);
        }
        dst[x].a = (uint8_t) DIV_255(dst[x].a * ainv + src * alpha);
    }
}

static inline void
    BB_multiply_y8_row(uint8_t * restrict dst, unsigned int w, uint8_t src)
{
    if (unlikely(w == 0) || src == 0xFF) {
        return;
    }
    if (src == 0) {
        memset(dst, 0, w);
        return;
    }

    unsigned int x = 0;
#if BB_HAS_ARM_NEON
    x = BB_multiply_y8_row_neon(dst, w, src);
#endif
    for (; x + 4U <= w; x += 4U) {
        BB_PREFETCH_WRITE(dst + x + 32U);
        dst[x]      = (uint8_t) DIV_255(dst[x]      * src);
        dst[x + 1U] = (uint8_t) DIV_255(dst[x + 1U] * src);
        dst[x + 2U] = (uint8_t) DIV_255(dst[x + 2U] * src);
        dst[x + 3U] = (uint8_t) DIV_255(dst[x + 3U] * src);
    }
    for (; x < w; x++) {
        dst[x] = (uint8_t) DIV_255(dst[x] * src);
    }
}

static inline void
    BB_multiply_y8a_luma_row(Color8A * restrict dst, unsigned int w, uint8_t src)
{
    if (unlikely(w == 0) || src == 0xFF) {
        return;
    }
    if (src == 0) {
        unsigned int x = 0;
#if BB_HAS_ARM_NEON
        x = BB_set_y8a_luma_row_neon(dst, w, 0);
#endif
        for (; x < w; x++) {
            dst[x].a = 0;
        }
        return;
    }

    unsigned int x = 0;
#if BB_HAS_ARM_NEON
    x = BB_multiply_y8a_luma_row_neon(dst, w, src);
#endif
    for (; x < w; x++) {
        if ((x & 31U) == 0) {
            BB_PREFETCH_WRITE(dst + x + 32U);
        }
        dst[x].a = (uint8_t) DIV_255(dst[x].a * src);
    }
}

static inline void
    BB_multiply_over_y8_row(uint8_t * restrict dst, unsigned int w, uint8_t src, uint8_t alpha)
{
    if (unlikely(w == 0 || alpha == 0) || src == 0xFF) {
        return;
    }
    if (alpha == 0xFF) {
        BB_multiply_y8_row(dst, w, src);
        return;
    }

    const uint8_t ainv = alpha ^ 0xFF;
    unsigned int x = 0;
#if BB_HAS_ARM_NEON
    x = BB_multiply_over_y8_row_neon(dst, w, src, alpha);
#endif
    for (; x < w; x++) {
        if ((x & 31U) == 0) {
            BB_PREFETCH_WRITE(dst + x + 32U);
        }
        const uint8_t multiplied = (uint8_t) DIV_255(dst[x] * src);
        dst[x] = (uint8_t) DIV_255(dst[x] * ainv + multiplied * alpha);
    }
}

static inline void
    BB_multiply_over_y8a_luma_row(Color8A * restrict dst, unsigned int w, uint8_t src, uint8_t alpha)
{
    if (unlikely(w == 0 || alpha == 0) || src == 0xFF) {
        return;
    }
    if (alpha == 0xFF) {
        BB_multiply_y8a_luma_row(dst, w, src);
        return;
    }

    const uint8_t ainv = alpha ^ 0xFF;
    unsigned int x = 0;
#if BB_HAS_ARM_NEON
    x = BB_multiply_over_y8a_luma_row_neon(dst, w, src, alpha);
#endif
    for (; x < w; x++) {
        if ((x & 31U) == 0) {
            BB_PREFETCH_WRITE(dst + x + 32U);
        }
        const uint8_t multiplied = (uint8_t) DIV_255(dst[x].a * src);
        dst[x].a = (uint8_t) DIV_255(dst[x].a * ainv + multiplied * alpha);
    }
}

// NOTE: See Pillow's transpose operations, or Qt5 qMemRotate stuff for cache-efficient ways of rotating an image data buffer,
//       instead of handling the rotation per-pixel, at plotting time.
//       I have no idea if it'd be an efficient method here, since it requires an extra buffer in which to do the rotation,
//       just so that new buffer can be used for the memcpy-based fast paths...

#define BB_GET_PIXEL(bb, rotation, COLOR, x, y, pptr) \
({ \
    if (rotation == 0) { \
        *pptr = (COLOR*)(bb->data + (y) * bb->stride) + (x); \
    } else if (rotation == 1) { \
        *pptr = (COLOR*)(bb->data + (x) * bb->stride) + bb->w - (y) - 1; \
    } else if (rotation == 2) { \
        *pptr = (COLOR*)(bb->data + (bb->h - (y) - 1) * bb->stride) + bb->w - (x) - 1; \
    } else if (rotation == 3) { \
        *pptr = (COLOR*)(bb->data + (bb->h - (x) - 1) * bb->stride) + (y); \
    } \
})

#define SET_ALPHA_FROM_A(bb, bb_type, bb_rotation, x, y, alpha) \
({ \
    if (bb_type == TYPE_BB8) { \
        const Color8 * restrict srcptr; \
        BB_GET_PIXEL(bb, bb_rotation, Color8, x, y, &srcptr); \
        *alpha = srcptr->a; \
    } else if (bb_type == TYPE_BB8A) { \
        const Color8A * restrict srcptr; \
        BB_GET_PIXEL(bb, bb_rotation, Color8A, x, y, &srcptr); \
        *alpha = srcptr->a; \
    } else if (bb_type == TYPE_BBRGB16) { \
        const ColorRGB16 * restrict srcptr; \
        BB_GET_PIXEL(bb, bb_rotation, ColorRGB16, x, y, &srcptr); \
        *alpha = (uint8_t) ColorRGB16_To_A(srcptr->v); \
    } else if (bb_type == TYPE_BBRGB24) { \
        const ColorRGB24 * restrict srcptr; \
        BB_GET_PIXEL(bb, bb_rotation, ColorRGB24, x, y, &srcptr); \
        *alpha = (uint8_t) RGB_To_A(srcptr->r, srcptr->g, srcptr->b); \
    } else if (bb_type == TYPE_BBRGB32) { \
        const ColorRGB32 * restrict srcptr; \
        BB_GET_PIXEL(bb, bb_rotation, ColorRGB32, x, y, &srcptr); \
        *alpha = (uint8_t) RGB_To_A(srcptr->r, srcptr->g, srcptr->b); \
    } \
})

static inline void BB8_SET_PIXEL_CLAMPED(BlitBuffer * restrict bb, int rotation, unsigned int x, unsigned int y, unsigned int width, unsigned int height, const Color8 * restrict color) {
    if (likely(x < width && y < height)) {
        Color8 * restrict pixel;
        BB_GET_PIXEL(bb, rotation, Color8, x, y, &pixel);
        *pixel = *color;
    }
}

static inline void BB8A_SET_PIXEL_CLAMPED(BlitBuffer * restrict bb, int rotation, unsigned int x, unsigned int y, unsigned int width, unsigned int height, const Color8A * restrict color) {
    if (likely(x < width && y < height)) {
        Color8A * restrict pixel;
        BB_GET_PIXEL(bb, rotation, Color8A, x, y, &pixel);
        *pixel = *color;
    }
}

static inline void BBRGB16_SET_PIXEL_CLAMPED(BlitBuffer * restrict bb, int rotation, unsigned int x, unsigned int y, unsigned int width, unsigned int height, const ColorRGB16 * restrict color) {
    if (likely(x < width && y < height)) {
        ColorRGB16 * restrict pixel;
        BB_GET_PIXEL(bb, rotation, ColorRGB16, x, y, &pixel);
        *pixel = *color;
    }
}

static inline void BBRGB24_SET_PIXEL_CLAMPED(BlitBuffer * restrict bb, int rotation, unsigned int x, unsigned int y, unsigned int width, unsigned int height, const ColorRGB24 * restrict color) {
    if (likely(x < width && y < height)) {
        ColorRGB24 * restrict pixel;
        BB_GET_PIXEL(bb, rotation, ColorRGB24, x, y, &pixel);
        *pixel = *color;
    }
}

static inline void BBRGB32_SET_PIXEL_CLAMPED(BlitBuffer * restrict bb, int rotation, unsigned int x, unsigned int y, unsigned int width, unsigned int height, const ColorRGB32 * restrict color) {
    if (likely(x < width && y < height)) {
        ColorRGB32 * restrict pixel;
        BB_GET_PIXEL(bb, rotation, ColorRGB32, x, y, &pixel);
        *pixel = *color;
    }
}

static inline void BB8_BLEND_PIXEL_CLAMPED(BlitBuffer * restrict bb, int rotation, unsigned int x, unsigned int y, unsigned int width, unsigned int height, const Color8A * restrict color) {
    if (likely(x < width && y < height)) {
        Color8 * restrict pixel;
        BB_GET_PIXEL(bb, rotation, Color8, x, y, &pixel);

        const uint8_t alpha = color->alpha;
        const uint8_t ainv = alpha ^ 0xff;

        pixel->a = (uint8_t) DIV_255(alpha * color->a + ainv * pixel->a);
    }
}
static inline void BB8A_BLEND_PIXEL_CLAMPED(BlitBuffer * restrict bb, int rotation, unsigned int x, unsigned int y, unsigned int width, unsigned int height, const Color8A * restrict color) {
    if (likely(x < width && y < height)) {
        Color8A * restrict pixel;
        BB_GET_PIXEL(bb, rotation, Color8A, x, y, &pixel);

        const uint8_t alpha = color->alpha;
        const uint8_t ainv = alpha ^ 0xff;

        pixel->a = (uint8_t) DIV_255(alpha * color->a + ainv * pixel->a);
        pixel->alpha = 0xff;
    }
}
static inline void BBRGB16_BLEND_PIXEL_CLAMPED(BlitBuffer * restrict bb, int rotation, unsigned int x, unsigned int y, unsigned int width, unsigned int height, const Color8A * restrict color) {
    if (likely(x < width && y < height)) {
        ColorRGB16 * restrict pixel;
        BB_GET_PIXEL(bb, rotation, ColorRGB16, x, y, &pixel);

        const uint8_t alpha = color->alpha;
        const uint8_t ainv = alpha ^ 0xff;

        const uint8_t r = (uint8_t) DIV_255(alpha * color->a + ainv * ColorRGB16_GetR(pixel->v));
        const uint8_t g = (uint8_t) DIV_255(alpha * color->a + ainv * ColorRGB16_GetG(pixel->v));
        const uint8_t b = (uint8_t) DIV_255(alpha * color->a + ainv * ColorRGB16_GetB(pixel->v));
        pixel->v = (uint16_t) RGB_To_RGB16(r, g, b);
    }
}

static inline void BBRGB24_BLEND_PIXEL_CLAMPED(BlitBuffer * restrict bb, int rotation, unsigned int x, unsigned int y, unsigned int width, unsigned int height, const ColorRGB32 * restrict color) {
    if (likely(x < width && y < height)) {
        ColorRGB24 * restrict pixel;
        BB_GET_PIXEL(bb, rotation, ColorRGB24, x, y, &pixel);

        const uint8_t alpha = color->alpha;
        const uint8_t ainv = alpha ^ 0xff;

        pixel->r = (uint8_t) DIV_255(alpha * color->r + ainv * pixel->r);
        pixel->g = (uint8_t) DIV_255(alpha * color->g + ainv * pixel->g);
        pixel->b = (uint8_t) DIV_255(alpha * color->b + ainv * pixel->b);
    }
}

static inline void BBRGB32_BLEND_PIXEL_CLAMPED(BlitBuffer * restrict bb, int rotation, unsigned int x, unsigned int y, unsigned int width, unsigned int height, const ColorRGB32 * restrict color) {
    if (likely(x < width && y < height)) {
        ColorRGB32 * restrict pixel;
        BB_GET_PIXEL(bb, rotation, ColorRGB32, x, y, &pixel);

        const uint8_t alpha = color->alpha;
        const uint8_t ainv = alpha ^ 0xff;

        pixel->r = (uint8_t) DIV_255(alpha * color->r + ainv * pixel->r);
        pixel->g = (uint8_t) DIV_255(alpha * color->g + ainv * pixel->g);
        pixel->b = (uint8_t) DIV_255(alpha * color->b + ainv * pixel->b);
        pixel->alpha = (uint8_t) 0xff;
    }
}

static inline unsigned int BB_GET_WIDTH(BlitBuffer * restrict bb) {
    if ((GET_BB_ROTATION(bb) & 1U) == 0U) {
        return bb->w;
    } else {
        return bb->h;
    }
}

static inline unsigned int BB_GET_HEIGHT(BlitBuffer * restrict bb) {
    if ((GET_BB_ROTATION(bb) & 1U) == 0U) {
        return bb->h;
    } else {
        return bb->w;
    }
}

void BB_fill(BlitBuffer * restrict bb, uint8_t v) {
    // Handle any target pitch properly
    const int bb_type = GET_BB_TYPE(bb);
    if (bb_type == TYPE_BB8) {
            //fprintf(stdout, "%s: BB8 fill\n", __FUNCTION__);
            uint8_t * restrict p = bb->data;
            memset(p, v, bb->stride*bb->h);
    } else if (bb_type == TYPE_BB8A) {
            // We do NOT want to stomp on the alpha byte here...
            const uint16_t src = (uint16_t) Y8_To_Y8A(v);
            //fprintf(stdout, "%s: BB8A fill\n", __FUNCTION__);
            uint16_t * restrict p = (uint16_t *) bb->data;
            size_t px_count = bb->pixel_stride*bb->h;
            while (px_count--) {
                *p++ = src;
            }
    } else if (bb_type == TYPE_BBRGB16) {
            // Again, RGB565 means we can't use a straight memset
            const uint16_t src = (uint16_t) RGB_To_RGB16(v, v, v);
            //fprintf(stdout, "%s: BBRGB16 fill\n", __FUNCTION__);
            uint16_t * restrict p = (uint16_t *) bb->data;
            size_t px_count = bb->pixel_stride*bb->h;
            while (px_count--) {
                *p++ = src;
            }
    } else if (bb_type == TYPE_BBRGB24) {
            //fprintf(stdout, "%s: BBRGB24 fill\n", __FUNCTION__);
            uint8_t * restrict p = bb->data;
            memset(p, v, bb->stride*bb->h);
    } else if (bb_type == TYPE_BBRGB32) {
            // And here either, as we want to preserve the alpha byte
            const uint32_t src = (uint32_t) Y8_To_RGB32(v);
            //fprintf(stdout, "%s: BBRGB32 fill\n", __FUNCTION__);
            uint32_t * restrict p = (uint32_t *) bb->data;
            size_t px_count = bb->pixel_stride*bb->h;
            while (px_count--) {
                *p++ = src;
            }
    }
}

void BB_fill_rect(BlitBuffer * restrict bb, unsigned int x, unsigned int y, unsigned int w, unsigned int h, uint8_t v) {
    const int rotation = GET_BB_ROTATION(bb);
    unsigned int rx, ry, rw, rh;
    // Compute rotated rectangle coordinates & size
    switch (rotation) {
        case 0:
                rx = x;
                ry = y;
                rw = w;
                rh = h;
                break;
        case 1:
                rx = bb->w - (y + h);
                ry = x;
                rw = h;
                rh = w;
                break;
        case 2:
                rx = bb->w - (x + w);
                ry = bb->h - (y + h);
                rw = w;
                rh = h;
                break;
        case 3:
                rx = y;
                ry = bb->h - (x + w);
                rw = h;
                rh = w;
                break;
    }

    // Handle any target pitch properly
    const int bb_type = GET_BB_TYPE(bb);
    switch (bb_type) {
        case TYPE_BB8:
            if (rx == 0 && rw == bb->w) {
                // Single step for contiguous scanlines (e.g., BB_fill())
                //fprintf(stdout, "%s: Full BB8 paintRect\n", __FUNCTION__);
                uint8_t * restrict p = bb->data + bb->stride*ry;
                memset(p, v, bb->stride*rh);
            } else {
                // Scanline per scanline
                //fprintf(stdout, "%s: Scanline BB8 paintRect\n", __FUNCTION__);
                for (unsigned int j = ry; j < ry+rh; j++) {
                    uint8_t * restrict p = bb->data + bb->stride*j + rx;
                    memset(p, v, rw);
                }
            }
            break;
        case TYPE_BB8A:
            // We do NOT want to stomp on the alpha byte here...
            if (rx == 0 && rw == bb->w) {
                // Single step for contiguous scanlines
                const uint16_t src = (uint16_t) Y8_To_Y8A(v);
                //fprintf(stdout, "%s: Full BB8A paintRect\n", __FUNCTION__);
                uint16_t * restrict p = (uint16_t *) (bb->data + bb->stride*ry);
                size_t px_count = bb->pixel_stride*rh;
                while (px_count--) {
                    *p++ = src;
                }
            } else {
                // Scanline per scanline
                const uint16_t src = (uint16_t) Y8_To_Y8A(v);
                //fprintf(stdout, "%s: Scanline BB8A paintRect\n", __FUNCTION__);
                for (unsigned int j = ry; j < ry+rh; j++) {
                    uint16_t * restrict p = (uint16_t *) (bb->data + bb->stride*j) + rx;
                    size_t px_count = rw;
                    while (px_count--) {
                        *p++ = src;
                    }
                }
            }
            break;
        case TYPE_BBRGB16:
            // Again, RGB565 means we can't use a straight memset
            if (rx == 0 && rw == bb->w) {
                // Single step for contiguous scanlines
                const uint16_t src = (uint16_t) RGB_To_RGB16(v, v, v);
                //fprintf(stdout, "%s: Full BBRGB16 paintRect\n", __FUNCTION__);
                uint16_t * restrict p = (uint16_t *) (bb->data + bb->stride*ry);
                size_t px_count = bb->pixel_stride*rh;
                while (px_count--) {
                    *p++ = src;
                }
            } else {
                // Scanline per scanline
                const uint16_t src = (uint16_t) RGB_To_RGB16(v, v, v);
                //fprintf(stdout, "%s: Sanline BBRGB16 paintRect\n", __FUNCTION__);
                for (unsigned int j = ry; j < ry+rh; j++) {
                    uint16_t * restrict p = (uint16_t *) (bb->data + bb->stride*j) + rx;
                    size_t px_count = rw;
                    while (px_count--) {
                        *p++ = src;
                    }
                }
            }
            break;
        case TYPE_BBRGB24:
            if (rx == 0 && rw == bb->w) {
                // Single step for contiguous scanlines
                //fprintf(stdout, "%s: Full BBRGB24 paintRect\n", __FUNCTION__);
                uint8_t * restrict p = bb->data + bb->stride*ry;
                memset(p, v, bb->stride*rh);
            } else {
                // Scanline per scanline
                //fprintf(stdout, "%s: Scanline BBRGB24 paintRect\n", __FUNCTION__);
                for (unsigned int j = ry; j < ry+rh; j++) {
                    uint8_t * restrict p = bb->data + bb->stride*j + (rx * 3U);
                    memset(p, v, (rw * 3U));
                }
            }
            break;
        case TYPE_BBRGB32:
            // And here either, as we want to preserve the alpha byte
            if (rx == 0 && rw == bb->w) {
                // Single step for contiguous scanlines
                const uint32_t src = (uint32_t) Y8_To_RGB32(v);
                //fprintf(stdout, "%s: Full BBRGB32 paintRect\n", __FUNCTION__);
                uint32_t * restrict p = (uint32_t *) (bb->data + bb->stride*ry);
                size_t px_count = bb->pixel_stride*rh;
                while (px_count--) {
                    *p++ = src;
                }
            } else {
                // Scanline per scanline
                const uint32_t src = (uint32_t) Y8_To_RGB32(v);
                //fprintf(stdout, "%s: Pixel BBRGB32 paintRect\n", __FUNCTION__);
                for (unsigned int j = ry; j < ry+rh; j++) {
                    uint32_t * restrict p = (uint32_t *) (bb->data + bb->stride*j) + rx;
                    size_t px_count = rw;
                    while (px_count--) {
                        *p++ = src;
                    }
                }
            }
            break;
    }
}

void BB_fill_rect_RGB32(BlitBuffer * restrict bb, unsigned int x, unsigned int y, unsigned int w, unsigned int h, const ColorRGB32 * restrict color) {
    const int rotation = GET_BB_ROTATION(bb);
    unsigned int rx, ry, rw, rh;
    // Compute rotated rectangle coordinates & size
    switch (rotation) {
        case 0:
                rx = x;
                ry = y;
                rw = w;
                rh = h;
                break;
        case 1:
                rx = bb->w - (y + h);
                ry = x;
                rw = h;
                rh = w;
                break;
        case 2:
                rx = bb->w - (x + w);
                ry = bb->h - (y + h);
                rw = w;
                rh = h;
                break;
        case 3:
                rx = y;
                ry = bb->h - (x + w);
                rw = h;
                rh = w;
                break;
    }

    // Handle any target pitch properly
    const int bb_type = GET_BB_TYPE(bb);
    switch (bb_type) {
        case TYPE_BB8:
            if (rx == 0 && rw == bb->w) {
                // Single step for contiguous scanlines (e.g., BB_fill())
                //fprintf(stdout, "%s: Full BB8 paintRect\n", __FUNCTION__);
                uint8_t * restrict p = bb->data + bb->stride*ry;
                memset(p, RGB_To_A(color->r, color->g, color->b), bb->stride*rh);
            } else {
                // Scanline per scanline
                //fprintf(stdout, "%s: Scanline BB8 paintRect\n", __FUNCTION__);
                const uint8_t source_y8 = RGB_To_A(color->r, color->g, color->b);
                for (unsigned int j = ry; j < ry+rh; j++) {
                    uint8_t * restrict p = bb->data + bb->stride*j + rx;
                    memset(p, source_y8, rw);
                }
            }
            break;
        case TYPE_BB8A:
            // We do NOT want to stomp on the alpha byte here...
            if (rx == 0 && rw == bb->w) {
                // Single step for contiguous scanlines
                const uint16_t src = (uint16_t) Y8_To_Y8A(RGB_To_A(color->r, color->g, color->b));
                //fprintf(stdout, "%s: Full BB8A paintRect\n", __FUNCTION__);
                uint16_t * restrict p = (uint16_t *) (bb->data + bb->stride*ry);
                size_t px_count = bb->pixel_stride*rh;
                while (px_count--) {
                    *p++ = src;
                }
            } else {
                // Scanline per scanline
                const uint16_t src = (uint16_t) Y8_To_Y8A(RGB_To_A(color->r, color->g, color->b));
                //fprintf(stdout, "%s: Scanline BB8A paintRect\n", __FUNCTION__);
                for (unsigned int j = ry; j < ry+rh; j++) {
                    uint16_t * restrict p = (uint16_t *) (bb->data + bb->stride*j) + rx;
                    size_t px_count = rw;
                    while (px_count--) {
                        *p++ = src;
                    }
                }
            }
            break;
        case TYPE_BBRGB16:
            // Again, RGB565 means we can't use a straight memset
            if (rx == 0 && rw == bb->w) {
                // Single step for contiguous scanlines
                const ColorRGB16 src = ColorRGB32_To_Color16(color);
                //fprintf(stdout, "%s: Full BBRGB16 paintRect\n", __FUNCTION__);
                ColorRGB16 * restrict p = (ColorRGB16 *) (bb->data + bb->stride*ry);
                size_t px_count = bb->pixel_stride*rh;
                while (px_count--) {
                    *p++ = src;
                }
            } else {
                // Scanline per scanline
                const ColorRGB16 src = ColorRGB32_To_Color16(color);
                //fprintf(stdout, "%s: Sanline BBRGB16 paintRect\n", __FUNCTION__);
                for (unsigned int j = ry; j < ry+rh; j++) {
                    ColorRGB16 * restrict p = (ColorRGB16 *) (bb->data + bb->stride*j) + rx;
                    size_t px_count = rw;
                    while (px_count--) {
                        *p++ = src;
                    }
                }
            }
            break;
        case TYPE_BBRGB24:
            {
                // Pixel per pixel
                const ColorRGB24 src = ColorRGB32_To_Color24(color);
                //fprintf(stdout, "%s: Pixel BBRGB24 paintRect\n", __FUNCTION__);
                for (unsigned int j = ry; j < ry+rh; j++) {
                    for (unsigned int k = rx; k < rx+rw; k++) {
                        uint8_t * restrict p = bb->data + bb->stride*j + (k * 3U);
                        memcpy(p, &src, 3);
                    }
                }
            }
            break;
        case TYPE_BBRGB32:
            // And here either, as we want to preserve the alpha byte
            if (rx == 0 && rw == bb->w) {
                // Single step for contiguous scanlines
                //fprintf(stdout, "%s: Full BBRGB32 paintRect\n", __FUNCTION__);
                ColorRGB32 * restrict p = (ColorRGB32 *) (bb->data + bb->stride*ry);
                size_t px_count = bb->pixel_stride*rh;
                while (px_count--) {
                    *p++ = *color;
                }
            } else {
                // Scanline per scanline
                //fprintf(stdout, "%s: Pixel BBRGB32 paintRect\n", __FUNCTION__);
                for (unsigned int j = ry; j < ry+rh; j++) {
                    ColorRGB32 * restrict p = (ColorRGB32 *) (bb->data + bb->stride*j) + rx;
                    size_t px_count = rw;
                    while (px_count--) {
                        *p++ = *color;
                    }
                }
            }
            break;
    }
}

void BB_blend_rect(BlitBuffer * restrict bb, unsigned int x, unsigned int y, unsigned int w, unsigned int h, const Color8A * restrict color) {
    const int bb_type = GET_BB_TYPE(bb);
    const int bb_rotation = GET_BB_ROTATION(bb);
    const uint8_t alpha = color->alpha;
    if (unlikely(w == 0 || h == 0 || alpha == 0)) {
        return;
    }
    if (bb_rotation == 0) {
        if (bb_type == TYPE_BB8) {
            for (unsigned int j = y; j < y + h; j++) {
                uint8_t * restrict dst = bb->data + bb->stride * j + x;
                BB_blend_y8_row(dst, w, color->a, alpha);
            }
            return;
        }
        if (bb_type == TYPE_BB8A) {
            for (unsigned int j = y; j < y + h; j++) {
                Color8A * restrict dst = (Color8A *)(bb->data + bb->stride * j) + x;
                BB_blend_y8a_luma_row(dst, w, color->a, alpha);
            }
            return;
        }
    }
    const uint8_t ainv = alpha ^ 0xFF;
    switch (bb_type) {
        case TYPE_BB8:
            for (unsigned int j = y; j < y + h; j++) {
                for (unsigned int i = x; i < x + w; i++) {
                    Color8 * restrict dstptr;
                    BB_GET_PIXEL(bb, bb_rotation, Color8, i, j, &dstptr);
                    dstptr->a = (uint8_t) DIV_255(dstptr->a * ainv + color->a * alpha);
                }
            }
            break;
        case TYPE_BB8A:
            for (unsigned int j = y; j < y + h; j++) {
                for (unsigned int i = x; i < x + w; i++) {
                    Color8A * restrict dstptr;
                    BB_GET_PIXEL(bb, bb_rotation, Color8A, i, j, &dstptr);
                    dstptr->a = (uint8_t) DIV_255(dstptr->a * ainv + color->a * alpha);
                }
            }
            break;
        case TYPE_BBRGB16:
            for (unsigned int j = y; j < y + h; j++) {
                for (unsigned int i = x; i < x + w; i++) {
                    ColorRGB16 * restrict dstptr;
                    BB_GET_PIXEL(bb, bb_rotation, ColorRGB16, i, j, &dstptr);
                    const uint8_t r = (uint8_t) DIV_255(ColorRGB16_GetR(dstptr->v) * ainv + color->a * alpha);
                    const uint8_t g = (uint8_t) DIV_255(ColorRGB16_GetG(dstptr->v) * ainv + color->a * alpha);
                    const uint8_t b = (uint8_t) DIV_255(ColorRGB16_GetB(dstptr->v) * ainv + color->a * alpha);
                    dstptr->v = (uint16_t) RGB_To_RGB16(r, g, b);
                }
            }
            break;
        case TYPE_BBRGB24:
            for (unsigned int j = y; j < y + h; j++) {
                for (unsigned int i = x; i < x + w; i++) {
                    ColorRGB24 * restrict dstptr;
                    BB_GET_PIXEL(bb, bb_rotation, ColorRGB24, i, j, &dstptr);
                    dstptr->r = (uint8_t) DIV_255(dstptr->r * ainv + color->a * alpha);
                    dstptr->g = (uint8_t) DIV_255(dstptr->g * ainv + color->a * alpha);
                    dstptr->b = (uint8_t) DIV_255(dstptr->b * ainv + color->a * alpha);
                }
            }
            break;
        case TYPE_BBRGB32:
            for (unsigned int j = y; j < y + h; j++) {
                for (unsigned int i = x; i < x + w; i++) {
                    ColorRGB32 * restrict dstptr;
                    BB_GET_PIXEL(bb, bb_rotation, ColorRGB32, i, j, &dstptr);
                    dstptr->r = (uint8_t) DIV_255(dstptr->r * ainv + color->a * alpha);
                    dstptr->g = (uint8_t) DIV_255(dstptr->g * ainv + color->a * alpha);
                    dstptr->b = (uint8_t) DIV_255(dstptr->b * ainv + color->a * alpha);
                }
            }
            break;
    }
}

void BB_blend_RGB32_over_rect(BlitBuffer * restrict bb, unsigned int x, unsigned int y, unsigned int w, unsigned int h, const ColorRGB32 * restrict color) {
    const int bb_type = GET_BB_TYPE(bb);
    const int bb_rotation = GET_BB_ROTATION(bb);
    const uint8_t alpha = color->alpha;
    if (unlikely(w == 0 || h == 0 || alpha == 0)) {
        return;
    }
    if (bb_rotation == 0 && (bb_type == TYPE_BB8 || bb_type == TYPE_BB8A)) {
        const uint8_t source_y8 = RGB_To_A(color->r, color->g, color->b);
        if (bb_type == TYPE_BB8) {
            for (unsigned int j = y; j < y + h; j++) {
                uint8_t * restrict dst = bb->data + bb->stride * j + x;
                BB_blend_y8_row(dst, w, source_y8, alpha);
            }
        } else {
            for (unsigned int j = y; j < y + h; j++) {
                Color8A * restrict dst = (Color8A *)(bb->data + bb->stride * j) + x;
                BB_blend_y8a_luma_row(dst, w, source_y8, alpha);
            }
        }
        return;
    }
    const uint8_t ainv = alpha ^ 0xFF;
    switch (bb_type) {
        case TYPE_BB8:
            {
                const uint8_t source_y8 = RGB_To_A(color->r, color->g, color->b);
                for (unsigned int j = y; j < y + h; j++) {
                    for (unsigned int i = x; i < x + w; i++) {
                        Color8 * restrict dstptr;
                        BB_GET_PIXEL(bb, bb_rotation, Color8, i, j, &dstptr);
                        dstptr->a = (uint8_t) DIV_255(dstptr->a * ainv + source_y8 * alpha);
                    }
                }
            }
            break;
        case TYPE_BB8A:
            {
                const uint8_t source_y8 = RGB_To_A(color->r, color->g, color->b);
                for (unsigned int j = y; j < y + h; j++) {
                    for (unsigned int i = x; i < x + w; i++) {
                        Color8A * restrict dstptr;
                        BB_GET_PIXEL(bb, bb_rotation, Color8A, i, j, &dstptr);
                        dstptr->a = (uint8_t) DIV_255(dstptr->a * ainv + source_y8 * alpha);
                    }
                }
            }
            break;
        case TYPE_BBRGB16:
            for (unsigned int j = y; j < y + h; j++) {
                for (unsigned int i = x; i < x + w; i++) {
                    ColorRGB16 * restrict dstptr;
                    BB_GET_PIXEL(bb, bb_rotation, ColorRGB16, i, j, &dstptr);
                    const uint8_t r = (uint8_t) DIV_255(ColorRGB16_GetR(dstptr->v) * ainv + color->r * alpha);
                    const uint8_t g = (uint8_t) DIV_255(ColorRGB16_GetG(dstptr->v) * ainv + color->g * alpha);
                    const uint8_t b = (uint8_t) DIV_255(ColorRGB16_GetB(dstptr->v) * ainv + color->b * alpha);
                    dstptr->v = (uint16_t) RGB_To_RGB16(r, g, b);
                }
            }
            break;
        case TYPE_BBRGB24:
            for (unsigned int j = y; j < y + h; j++) {
                for (unsigned int i = x; i < x + w; i++) {
                    ColorRGB24 * restrict dstptr;
                    BB_GET_PIXEL(bb, bb_rotation, ColorRGB24, i, j, &dstptr);
                    dstptr->r = (uint8_t) DIV_255(dstptr->r * ainv + color->r * alpha);
                    dstptr->g = (uint8_t) DIV_255(dstptr->g * ainv + color->g * alpha);
                    dstptr->b = (uint8_t) DIV_255(dstptr->b * ainv + color->b * alpha);
                }
            }
            break;
        case TYPE_BBRGB32:
            for (unsigned int j = y; j < y + h; j++) {
                for (unsigned int i = x; i < x + w; i++) {
                    ColorRGB32 * restrict dstptr;
                    BB_GET_PIXEL(bb, bb_rotation, ColorRGB32, i, j, &dstptr);
                    dstptr->r = (uint8_t) DIV_255(dstptr->r * ainv + color->r * alpha);
                    dstptr->g = (uint8_t) DIV_255(dstptr->g * ainv + color->g * alpha);
                    dstptr->b = (uint8_t) DIV_255(dstptr->b * ainv + color->b * alpha);
                }
            }
            break;
    }
}

// Dumb multiply blending mode (used for painting book highlights)
void BB_blend_RGB_multiply_rect(BlitBuffer * restrict bb, unsigned int x, unsigned int y, unsigned int w, unsigned int h, const ColorRGB24 * restrict color) {
    const int bb_type = GET_BB_TYPE(bb);
    const int bb_rotation = GET_BB_ROTATION(bb);
    if (unlikely(w == 0 || h == 0)) {
        return;
    }
    if (bb_rotation == 0 && (bb_type == TYPE_BB8 || bb_type == TYPE_BB8A)) {
        const uint8_t source_y8 = RGB_To_A(color->r, color->g, color->b);
        if (bb_type == TYPE_BB8) {
            for (unsigned int j = y; j < y + h; j++) {
                uint8_t * restrict dst = bb->data + bb->stride * j + x;
                BB_multiply_y8_row(dst, w, source_y8);
            }
        } else {
            for (unsigned int j = y; j < y + h; j++) {
                Color8A * restrict dst = (Color8A *)(bb->data + bb->stride * j) + x;
                BB_multiply_y8a_luma_row(dst, w, source_y8);
            }
        }
        return;
    }
    switch (bb_type) {
        case TYPE_BB8:
            {
                const uint8_t source_y8 = RGB_To_A(color->r, color->g, color->b);
                for (unsigned int j = y; j < y + h; j++) {
                    for (unsigned int i = x; i < x + w; i++) {
                        Color8 * restrict dstptr;
                        BB_GET_PIXEL(bb, bb_rotation, Color8, i, j, &dstptr);
                        dstptr->a = (uint8_t) DIV_255(dstptr->a * source_y8);
                    }
                }
            }
            break;
        case TYPE_BB8A:
            {
                const uint8_t source_y8 = RGB_To_A(color->r, color->g, color->b);
                for (unsigned int j = y; j < y + h; j++) {
                    for (unsigned int i = x; i < x + w; i++) {
                        Color8A * restrict dstptr;
                        BB_GET_PIXEL(bb, bb_rotation, Color8A, i, j, &dstptr);
                        dstptr->a = (uint8_t) DIV_255(dstptr->a * source_y8);
                    }
                }
            }
            break;
        case TYPE_BBRGB16:
            for (unsigned int j = y; j < y + h; j++) {
                for (unsigned int i = x; i < x + w; i++) {
                    ColorRGB16 * restrict dstptr;
                    BB_GET_PIXEL(bb, bb_rotation, ColorRGB16, i, j, &dstptr);
                    const uint8_t r = (uint8_t) DIV_255(ColorRGB16_GetR(dstptr->v) * color->r);
                    const uint8_t g = (uint8_t) DIV_255(ColorRGB16_GetG(dstptr->v) * color->g);
                    const uint8_t b = (uint8_t) DIV_255(ColorRGB16_GetB(dstptr->v) * color->b);
                    dstptr->v = (uint16_t) RGB_To_RGB16(r, g, b);
                }
            }
            break;
        case TYPE_BBRGB24:
            for (unsigned int j = y; j < y + h; j++) {
                for (unsigned int i = x; i < x + w; i++) {
                    ColorRGB24 * restrict dstptr;
                    BB_GET_PIXEL(bb, bb_rotation, ColorRGB24, i, j, &dstptr);
                    dstptr->r = (uint8_t) DIV_255(dstptr->r * color->r);
                    dstptr->g = (uint8_t) DIV_255(dstptr->g * color->g);
                    dstptr->b = (uint8_t) DIV_255(dstptr->b * color->b);
                }
            }
            break;
        case TYPE_BBRGB32:
            for (unsigned int j = y; j < y + h; j++) {
                for (unsigned int i = x; i < x + w; i++) {
                    ColorRGB32 * restrict dstptr;
                    BB_GET_PIXEL(bb, bb_rotation, ColorRGB32, i, j, &dstptr);
                    dstptr->r = (uint8_t) DIV_255(dstptr->r * color->r);
                    dstptr->g = (uint8_t) DIV_255(dstptr->g * color->g);
                    dstptr->b = (uint8_t) DIV_255(dstptr->b * color->b);
                }
            }
            break;
    }
}

// Fancier variant if we ever want to honor color's alpha...
// Function name is a slight misnommer, as we're essentially doing (color MUL rect) OVER rect
void BB_blend_RGB32_multiply_rect(BlitBuffer * restrict bb, unsigned int x, unsigned int y, unsigned int w, unsigned int h, const ColorRGB32 * restrict color) {
    const int bb_type = GET_BB_TYPE(bb);
    const int bb_rotation = GET_BB_ROTATION(bb);
    const uint8_t alpha = color->alpha;
    if (unlikely(w == 0 || h == 0 || alpha == 0)) {
        return;
    }
    if (bb_rotation == 0 && (bb_type == TYPE_BB8 || bb_type == TYPE_BB8A)) {
        const uint8_t source_y8 = RGB_To_A(color->r, color->g, color->b);
        if (bb_type == TYPE_BB8) {
            for (unsigned int j = y; j < y + h; j++) {
                uint8_t * restrict dst = bb->data + bb->stride * j + x;
                BB_multiply_over_y8_row(dst, w, source_y8, alpha);
            }
        } else {
            for (unsigned int j = y; j < y + h; j++) {
                Color8A * restrict dst = (Color8A *)(bb->data + bb->stride * j) + x;
                BB_multiply_over_y8a_luma_row(dst, w, source_y8, alpha);
            }
        }
        return;
    }
    const uint8_t ainv = alpha ^ 0xFF;
    switch (bb_type) {
        case TYPE_BB8:
            {
                const uint8_t source_y8 = RGB_To_A(color->r, color->g, color->b);
                for (unsigned int j = y; j < y + h; j++) {
                    for (unsigned int i = x; i < x + w; i++) {
                        Color8 * restrict dstptr;
                        BB_GET_PIXEL(bb, bb_rotation, Color8, i, j, &dstptr);
                        dstptr->a = (uint8_t) DIV_255(dstptr->a * ainv + DIV_255(dstptr->a * source_y8) * alpha);
                    }
                }
            }
            break;
        case TYPE_BB8A:
            {
                const uint8_t source_y8 = RGB_To_A(color->r, color->g, color->b);
                for (unsigned int j = y; j < y + h; j++) {
                    for (unsigned int i = x; i < x + w; i++) {
                        Color8A * restrict dstptr;
                        BB_GET_PIXEL(bb, bb_rotation, Color8A, i, j, &dstptr);
                        dstptr->a = (uint8_t) DIV_255(dstptr->a * ainv + DIV_255(dstptr->a * source_y8) * alpha);
                    }
                }
            }
            break;
        case TYPE_BBRGB16:
            for (unsigned int j = y; j < y + h; j++) {
                for (unsigned int i = x; i < x + w; i++) {
                    ColorRGB16 * restrict dstptr;
                    BB_GET_PIXEL(bb, bb_rotation, ColorRGB16, i, j, &dstptr);
                    const uint8_t dr = ColorRGB16_GetR(dstptr->v);
                    const uint8_t dg = ColorRGB16_GetR(dstptr->v);
                    const uint8_t db = ColorRGB16_GetR(dstptr->v);
                    const uint8_t r = (uint8_t) DIV_255(dr * ainv + DIV_255(dr * color->r) * alpha);
                    const uint8_t g = (uint8_t) DIV_255(dg * ainv + DIV_255(dg * color->g) * alpha);
                    const uint8_t b = (uint8_t) DIV_255(db * ainv + DIV_255(db * color->b) * alpha);
                    dstptr->v = (uint16_t) RGB_To_RGB16(r, g, b);
                }
            }
            break;
        case TYPE_BBRGB24:
            for (unsigned int j = y; j < y + h; j++) {
                for (unsigned int i = x; i < x + w; i++) {
                    ColorRGB24 * restrict dstptr;
                    BB_GET_PIXEL(bb, bb_rotation, ColorRGB24, i, j, &dstptr);
                    dstptr->r = (uint8_t) DIV_255(dstptr->r * ainv + DIV_255(dstptr->r * color->r) * alpha);
                    dstptr->g = (uint8_t) DIV_255(dstptr->g * ainv + DIV_255(dstptr->g * color->g) * alpha);
                    dstptr->b = (uint8_t) DIV_255(dstptr->b * ainv + DIV_255(dstptr->b * color->b) * alpha);
                }
            }
            break;
        case TYPE_BBRGB32:
            for (unsigned int j = y; j < y + h; j++) {
                for (unsigned int i = x; i < x + w; i++) {
                    ColorRGB32 * restrict dstptr;
                    BB_GET_PIXEL(bb, bb_rotation, ColorRGB32, i, j, &dstptr);
                    dstptr->r = (uint8_t) DIV_255(dstptr->r * ainv + DIV_255(dstptr->r * color->r) * alpha);
                    dstptr->g = (uint8_t) DIV_255(dstptr->g * ainv + DIV_255(dstptr->g * color->g) * alpha);
                    dstptr->b = (uint8_t) DIV_255(dstptr->b * ainv + DIV_255(dstptr->b * color->b) * alpha);
                }
            }
            break;
    }
}

void BB_invert_rect(BlitBuffer * restrict bb, unsigned int x, unsigned int y, unsigned int w, unsigned int h) {
    const int rotation = GET_BB_ROTATION(bb);
    unsigned int rx, ry, rw, rh;
    // Compute rotated rectangle coordinates & size
    switch (rotation) {
        case 0:
                rx = x;
                ry = y;
                rw = w;
                rh = h;
                break;
        case 1:
                rx = bb->w - (y + h);
                ry = x;
                rw = h;
                rh = w;
                break;
        case 2:
                rx = bb->w - (x + w);
                ry = bb->h - (y + h);
                rw = w;
                rh = h;
                break;
        case 3:
                rx = y;
                ry = bb->h - (x + w);
                rw = h;
                rh = w;
                break;
    }
    // Handle any target pitch properly
    const int bb_type = GET_BB_TYPE(bb);
    switch (bb_type) {
        case TYPE_BB8:
            if (rx == 0 && rw == bb->w) {
                // Single step for contiguous scanlines
                //fprintf(stdout, "%s: Full BB8 invertRect\n", __FUNCTION__);
                uint8_t * restrict p = bb->data + bb->stride*ry;
                size_t px_count = bb->pixel_stride*rh;
                while (px_count--) {
                    *p++ ^= 0xFF;
                }
            } else {
                // Scanline per scanline
                //fprintf(stdout, "%s: Scanline BB8 invertRect\n", __FUNCTION__);
                for (unsigned int j = ry; j < ry+rh; j++) {
                    uint8_t * restrict p = bb->data + bb->stride*j + rx;
                    size_t px_count = rw;
                    while (px_count--) {
                        *p++ ^= 0xFF;
                    }
                }
            }
            break;
        case TYPE_BB8A:
            if (rx == 0 && rw == bb->w) {
                // Single step for contiguous scanlines
                //fprintf(stdout, "%s: Full BB8A invertRect\n", __FUNCTION__);
                uint16_t * restrict p = (uint16_t*) (bb->data + bb->stride*ry);
                size_t px_count = bb->pixel_stride*rh;
                while (px_count--) {
                    *p++ ^= 0x00FF;
                }
            } else {
                // Scanline per scanline
                //fprintf(stdout, "%s: Scanline BB8A invertRect\n", __FUNCTION__);
                for (unsigned int j = ry; j < ry+rh; j++) {
                    uint16_t * restrict p = (uint16_t*) (bb->data + bb->stride*j) + rx;
                    size_t px_count = rw;
                    while (px_count--) {
                        *p++ ^= 0x00FF;
                    }
                }
            }
            break;
        case TYPE_BBRGB16:
            // NOTE: Not actually accurate, but RGB565 is the worst.
            if (rx == 0 && rw == bb->w) {
                // Single step for contiguous scanlines
                //fprintf(stdout, "%s: Full BBRGB16 invertRect\n", __FUNCTION__);
                uint16_t * restrict p = (uint16_t*) (bb->data + bb->stride*ry);
                size_t px_count = bb->pixel_stride*rh;
                while (px_count--) {
                    *p++ ^= 0xFFFF;
                }
            } else {
                // Scanline per scanline
                //fprintf(stdout, "%s: Scanline BBRGB16 invertRect\n", __FUNCTION__);
                for (unsigned int j = ry; j < ry+rh; j++) {
                    uint16_t * restrict p = (uint16_t*) (bb->data + bb->stride*j) + rx;
                    size_t px_count = rw;
                    while (px_count--) {
                        *p++ ^= 0xFFFF;
                    }
                }
            }
            break;
        case TYPE_BBRGB24:
            if (rx == 0 && rw == bb->w) {
                // Single step for contiguous scanlines
                //fprintf(stdout, "%s: Full BBRGB24 invertRect\n", __FUNCTION__);
                uint8_t * restrict p = bb->data + bb->stride*ry;
                size_t px_count = bb->pixel_stride*rh;
                while (px_count--) {
                    *p++ ^= 0xFF;
                    *p++ ^= 0xFF;
                    *p++ ^= 0xFF;
                }
            } else {
                // Scanline per scanline
                //fprintf(stdout, "%s: Scanline BBRGB24 invertRect\n", __FUNCTION__);
                for (unsigned int j = ry; j < ry+rh; j++) {
                    uint8_t * restrict p = bb->data + bb->stride*j + (rx * 3U);
                    size_t px_count = rw;
                    while (px_count--) {
                        *p++ ^= 0xFF;
                        *p++ ^= 0xFF;
                        *p++ ^= 0xFF;
                    }
                }
            }
            break;
        case TYPE_BBRGB32:
            if (rx == 0 && rw == bb->w) {
                // Single step for contiguous scanlines
                //fprintf(stdout, "%s: Full BBRGB32 invertRect\n", __FUNCTION__);
                uint32_t * restrict p = (uint32_t*) (bb->data + bb->stride*ry);
                size_t px_count = bb->pixel_stride*rh;
                while (px_count--) {
                    *p++ ^= 0x00FFFFFF;
                }
            } else {
                // Scanline per scanline
                //fprintf(stdout, "%s: Scanline BBRGB32 invertRect\n", __FUNCTION__);
                for (unsigned int j = ry; j < ry+rh; j++) {
                    uint32_t * restrict p = (uint32_t*) (bb->data + bb->stride*j) + rx;
                    size_t px_count = rw;
                    while (px_count--) {
                        *p++ ^= 0x00FFFFFF;
                    }
                }
            }
            break;
    }
}

void BB_hatch_rect(BlitBuffer * restrict bb, unsigned int x, unsigned int y, unsigned int w, unsigned int h, unsigned int stripe_width, const Color8 * restrict color, uint8_t alpha) {
    if (alpha == 0) { // NOP
        return;
    }
    const uint8_t ainv = alpha ^ 0xFF;
    const int bb_type = GET_BB_TYPE(bb);
    const int rotation = GET_BB_ROTATION(bb);
    const int sw2 = stripe_width * 2;
    switch (bb_type) {
        case TYPE_BB8:
            if (alpha == 0xFF) {
                for (unsigned int d_y = 0; d_y < h; d_y++) {
                    for (unsigned int d_x = 0; d_x < w; d_x++) {
                        if ((d_x + d_y) % sw2 < stripe_width) {
                            Color8 * restrict dstptr;
                            BB_GET_PIXEL(bb, rotation, Color8, x+d_x, y+d_y, &dstptr);
                            *dstptr = *color;
                        }
                    }
                }
            } else {
                for (unsigned int d_y = 0; d_y < h; d_y++) {
                    for (unsigned int d_x = 0; d_x < w; d_x++) {
                        if ((d_x + d_y) % sw2 < stripe_width) {
                            Color8 * restrict dstptr;
                            BB_GET_PIXEL(bb, rotation, Color8, x+d_x, y+d_y, &dstptr);
                            dstptr->a = (uint8_t) DIV_255(dstptr->a * ainv + color->a * alpha);
                        }
                    }
                }
            }
            break;
        case TYPE_BB8A:
            if (alpha == 0xFF) {
                for (unsigned int d_y = 0; d_y < h; d_y++) {
                    for (unsigned int d_x = 0; d_x < w; d_x++) {
                        if ((d_x + d_y) % sw2 < stripe_width) {
                            Color8A * restrict dstptr;
                            BB_GET_PIXEL(bb, rotation, Color8A, x+d_x, y+d_y, &dstptr);
                            dstptr->a = color->a;
                        }
                    }
                }
            } else {
                for (unsigned int d_y = 0; d_y < h; d_y++) {
                    for (unsigned int d_x = 0; d_x < w; d_x++) {
                        if ((d_x + d_y) % sw2 < stripe_width) {
                            Color8A * restrict dstptr;
                            BB_GET_PIXEL(bb, rotation, Color8A, x+d_x, y+d_y, &dstptr);
                            dstptr->a = (uint8_t) DIV_255(dstptr->a * ainv + color->a * alpha);
                        }
                    }
                }
            }
            break;
        case TYPE_BBRGB16:
            if (alpha == 0xFF) {
                for (unsigned int d_y = 0; d_y < h; d_y++) {
                    for (unsigned int d_x = 0; d_x < w; d_x++) {
                        if ((d_x + d_y) % sw2 < stripe_width) {
                            ColorRGB16 * restrict dstptr;
                            BB_GET_PIXEL(bb, rotation, ColorRGB16, x + d_x, y + d_y, &dstptr);
                            dstptr->v = (uint16_t) RGB_To_RGB16(color->a, color->a, color->a);
                        }
                    }
                }
            } else {
                for (unsigned int d_y = 0; d_y < h; d_y++) {
                    for (unsigned int d_x = 0; d_x < w; d_x++) {
                        if ((d_x + d_y) % sw2 < stripe_width) {
                            ColorRGB16 * restrict dstptr;
                            BB_GET_PIXEL(bb, rotation, ColorRGB16, x + d_x, y + d_y, &dstptr);
                            const uint8_t r = (uint8_t) DIV_255(ColorRGB16_GetR(dstptr->v) * ainv + color->a * alpha);
                            const uint8_t g = (uint8_t) DIV_255(ColorRGB16_GetG(dstptr->v) * ainv + color->a * alpha);
                            const uint8_t b = (uint8_t) DIV_255(ColorRGB16_GetB(dstptr->v) * ainv + color->a * alpha);
                            dstptr->v = (uint16_t) RGB_To_RGB16(r, g, b);
                        }
                    }
                }
            }
            break;
        case TYPE_BBRGB24:
            if (alpha == 0xFF) {
                for (unsigned int d_y = 0; d_y < h; d_y++) {
                    for (unsigned int d_x = 0; d_x < w; d_x++) {
                        if ((d_x + d_y) % sw2 < stripe_width) {
                            ColorRGB24 * restrict dstptr;
                            BB_GET_PIXEL(bb, rotation, ColorRGB24, x + d_x, y + d_y, &dstptr);
                            dstptr->r = color->a;
                            dstptr->g = color->a;
                            dstptr->b = color->a;
                        }
                    }
                }
            } else {
                for (unsigned int d_y = 0; d_y < h; d_y++) {
                    for (unsigned int d_x = 0; d_x < w; d_x++) {
                        if ((d_x + d_y) % sw2 < stripe_width) {
                            ColorRGB24 * restrict dstptr;
                            BB_GET_PIXEL(bb, rotation, ColorRGB24, x + d_x, y + d_y, &dstptr);
                            dstptr->r = (uint8_t) DIV_255(dstptr->r * ainv + color->a * alpha);
                            dstptr->g = (uint8_t) DIV_255(dstptr->g * ainv + color->a * alpha);
                            dstptr->b = (uint8_t) DIV_255(dstptr->b * ainv + color->a * alpha);
                        }
                    }
                }
            }
            break;
        case TYPE_BBRGB32:
            if (alpha == 0xFF) {
                for (unsigned int d_y = 0; d_y < h; d_y++) {
                    for (unsigned int d_x = 0; d_x < w; d_x++) {
                        if ((d_x + d_y) % sw2 < stripe_width) {
                            ColorRGB32 * restrict dstptr;
                            BB_GET_PIXEL(bb, rotation, ColorRGB32, x + d_x, y + d_y, &dstptr);
                            dstptr->r = (uint8_t) color->a;
                            dstptr->g = (uint8_t) color->a;
                            dstptr->b = (uint8_t) color->a;
                            // dstptr->alpha = 0xFF;
                        }
                    }
                }
            } else {
                for (unsigned int d_y = 0; d_y < h; d_y++) {
                    for (unsigned int d_x = 0; d_x < w; d_x++) {
                        if ((d_x + d_y) % sw2 < stripe_width) {
                            ColorRGB32 * restrict dstptr;
                            BB_GET_PIXEL(bb, rotation, ColorRGB32, x + d_x, y + d_y, &dstptr);
                            dstptr->r = (uint8_t) DIV_255(dstptr->r * ainv + color->a * alpha);
                            dstptr->g = (uint8_t) DIV_255(dstptr->g * ainv + color->a * alpha);
                            dstptr->b = (uint8_t) DIV_255(dstptr->b * ainv + color->a * alpha);
                            // dstptr->alpha = 0xFF;
                        }
                    }
                }
            }
            break;
    }
}

void BB_blit_to_BB8(const BlitBuffer * restrict src, BlitBuffer * restrict dst,
        unsigned int dest_x, unsigned int dest_y, unsigned int offs_x, unsigned int offs_y, unsigned int w, unsigned int h) {
    const int sbb_type = GET_BB_TYPE(src);
    const int sbb_rotation = GET_BB_ROTATION(src);
    const int dbb_rotation = GET_BB_ROTATION(dst);
    switch (sbb_type) {
        case TYPE_BB8:
            // We can only do a fast copy for simple same-to-same blitting without any extra processing.
            // (i.e., setPixel, no rota, no invert).
            // The cbb codepath ensures setPixel & no invert, so we only check for rotation.
            if (sbb_rotation == 0 && dbb_rotation == 0) {
                const uint8_t * restrict srcp = src->data + src->stride*offs_y + offs_x;
                uint8_t * restrict dstp = dst->data + dst->stride*dest_y + dest_x;
                BB_copy_rows(dstp, dst->stride, srcp, src->stride, w, h);
            } else {
                for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                    for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                        Color8 * restrict dstptr;
                        BB_GET_PIXEL(dst, dbb_rotation, Color8, d_x, d_y, &dstptr);
                        const Color8 * restrict srcptr;
                        BB_GET_PIXEL(src, sbb_rotation, Color8, o_x, o_y, &srcptr);
                        *dstptr = *srcptr;
                    }
                }
            }
            break;
        case TYPE_BB8A:
            if (sbb_rotation == 0 && dbb_rotation == 0) {
                for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                    Color8 * restrict dstp = (Color8 *) (dst->data + dst->stride*d_y) + dest_x;
                    const Color8A * restrict srcp = (const Color8A *) (src->data + src->stride*o_y) + offs_x;
                    for (unsigned int x = 0; x < w; x++) {
                        dstp[x].a = srcp[x].a;
                    }
                }
            } else {
                for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                    for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                        Color8 * restrict dstptr;
                        BB_GET_PIXEL(dst, dbb_rotation, Color8, d_x, d_y, &dstptr);
                        const Color8A * restrict srcptr;
                        BB_GET_PIXEL(src, sbb_rotation, Color8A, o_x, o_y, &srcptr);
                        dstptr->a = srcptr->a;
                    }
                }
            }
            break;
        case TYPE_BBRGB16:
            for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                    Color8 * restrict dstptr;
                    BB_GET_PIXEL(dst, dbb_rotation, Color8, d_x, d_y, &dstptr);
                    const ColorRGB16 * restrict srcptr;
                    BB_GET_PIXEL(src, sbb_rotation, ColorRGB16, o_x, o_y, &srcptr);
                    dstptr->a = (uint8_t) ColorRGB16_To_A(srcptr->v);
                }
            }
            break;
        case TYPE_BBRGB24:
            for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                    Color8 * restrict dstptr;
                    BB_GET_PIXEL(dst, dbb_rotation, Color8, d_x, d_y, &dstptr);
                    const ColorRGB24 * restrict srcptr;
                    BB_GET_PIXEL(src, sbb_rotation, ColorRGB24, o_x, o_y, &srcptr);
                    dstptr->a = (uint8_t) RGB_To_A(srcptr->r, srcptr->g, srcptr->b);
                }
            }
            break;
        case TYPE_BBRGB32:
            if (sbb_rotation == 0 && dbb_rotation == 0) {
                for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                    Color8 * restrict dstp = (Color8 *) (dst->data + dst->stride*d_y) + dest_x;
                    const ColorRGB32 * restrict srcp = (const ColorRGB32 *) (src->data + src->stride*o_y) + offs_x;
                    BB_rgb32_to_bb8_row(dstp, srcp, w);
                }
            } else {
                for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                    for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                        Color8 * restrict dstptr;
                        BB_GET_PIXEL(dst, dbb_rotation, Color8, d_x, d_y, &dstptr);
                        const ColorRGB32 * restrict srcptr;
                        BB_GET_PIXEL(src, sbb_rotation, ColorRGB32, o_x, o_y, &srcptr);
                        dstptr->a = (uint8_t) RGB_To_A(srcptr->r, srcptr->g, srcptr->b);
                    }
                }
            }
            break;
    }
}

// Quantize an 8-bit color value down to a palette of 16 evenly spaced colors, using an ordered 8x8 dithering pattern.
// With a grayscale input, this happens to match the eInk palette perfectly ;).
// If the input is not grayscale, and the output fb is not grayscale either,
// this usually still happens to match the eInk palette after the EPDC's own quantization pass.
// c.f., https://en.wikipedia.org/wiki/Ordered_dithering
// & https://github.com/ImageMagick/ImageMagick/blob/ecfeac404e75f304004f0566557848c53030bad6/MagickCore/threshold.c#L1627
// NOTE: As the references imply, this is straight from ImageMagick,
//       with only minor simplifications to enforce Q8 & avoid fp maths.
// c.f., https://github.com/ImageMagick/ImageMagick/blob/ecfeac404e75f304004f0566557848c53030bad6/config/thresholds.xml#L107
static const uint8_t threshold_map_o8x8[] = { 1,  49, 13, 61, 4,  52, 16, 64, 33, 17, 45, 29, 36, 20, 48, 32,
                        9,  57, 5,  53, 12, 60, 8,  56, 41, 25, 37, 21, 44, 28, 40, 24,
                        3,  51, 15, 63, 2,  50, 14, 62, 35, 19, 47, 31, 34, 18, 46, 30,
                        11, 59, 7,  55, 10, 58, 6,  54, 43, 27, 39, 23, 42, 26, 38, 22 };

static uint8_t dither_o8x8_lut[64][256];
static bool dither_o8x8_lut_ready = false;

static inline uint8_t
    dither_o8x8_compute(uint8_t threshold, uint8_t v)
{
    // Constants:
    // Quantum = 8; Levels = 16; map Divisor = 65
    // QuantumRange = 0xFF
    // QuantumScale = 1.0 / QuantumRange
    //
    // threshold = QuantumScale * v * ((L-1) * (D-1) + 1)
    // NOTE: The initial computation of t (specifically, what we pass to DIV255) would overflow an uint8_t.
    //       With a Q8 input value, we're at no risk of ever underflowing, so, keep to unsigned maths.
    //       Technically, an uint16_t would be wide enough, but it gains us nothing,
    //       and requires a few explicit casts to make GCC happy ;).
    uint32_t t = DIV_255(v * ((15U << 6U) + 1U));
    // level = t / (D-1);
    const uint32_t l = (t >> 6U);
    // t -= l * (D-1);
    t = (t - (l << 6U));

    // map width & height = 8
    // c = ClampToQuantum((l+(t >= map[(x % mw) + mw * (y % mh)])) * QuantumRange / (L-1));
    const uint32_t q = ((l + (t >= threshold)) * 17U);
    // NOTE: We're doing unsigned maths, so, clamping is basically MIN(q, UINT8_MAX) ;).
    //       The only overflow we should ever catch should be for a few white (v = 0xFF) input pixels
    //       that get shifted to the next step (i.e., q = 272 (0xFF + 17)).
    return (q > UINT8_MAX ? UINT8_MAX : (uint8_t) q);
}

static void
    dither_o8x8_init_lut(void)
{
    if (likely(dither_o8x8_lut_ready)) {
        return;
    }

    for (unsigned int phase = 0; phase < 64; phase++) {
        const uint8_t threshold = threshold_map_o8x8[phase];
        for (unsigned int v = 0; v < 256; v++) {
            dither_o8x8_lut[phase][v] = dither_o8x8_compute(threshold, (uint8_t) v);
        }
    }
    dither_o8x8_lut_ready = true;
}

static inline const uint8_t (*dither_o8x8_get_lut(void))[256]
{
    if (unlikely(!dither_o8x8_lut_ready)) {
        dither_o8x8_init_lut();
    }
    return dither_o8x8_lut;
}

static inline uint8_t
    dither_o8x8(unsigned int x, unsigned int y, uint8_t v)
{
    const uint8_t (* restrict lut)[256] = dither_o8x8_get_lut();
    return lut[(x & 7U) + 8U * (y & 7U)][v];
}

void BB_dither_blit_to_BB8(const BlitBuffer * restrict src, BlitBuffer * restrict dst,
        unsigned int dest_x, unsigned int dest_y, unsigned int offs_x, unsigned int offs_y, unsigned int w, unsigned int h) {
    const int sbb_type = GET_BB_TYPE(src);
    const int sbb_rotation = GET_BB_ROTATION(src);
    const int dbb_rotation = GET_BB_ROTATION(dst);
    const uint8_t (* restrict dither_lut)[256] = NULL;
    switch (sbb_type) {
        case TYPE_BB8:
            if (sbb_rotation == 0 && dbb_rotation == 0) {
                dither_lut = dither_o8x8_get_lut();
                for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                    Color8 * restrict dstp = (Color8 *) (dst->data + dst->stride*d_y) + dest_x;
                    const Color8 * restrict srcp = (const Color8 *) (src->data + src->stride*o_y) + offs_x;
                    const unsigned int row_phase = (o_y & 7U) << 3U;
                    unsigned int col_phase = offs_x & 7U;
                    for (unsigned int x = 0; x < w; x++) {
                        dstp[x].a = dither_lut[row_phase + col_phase][srcp[x].a];
                        col_phase = (col_phase + 1U) & 7U;
                    }
                }
            } else {
                for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                    for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                        Color8 * restrict dstptr;
                        BB_GET_PIXEL(dst, dbb_rotation, Color8, d_x, d_y, &dstptr);
                        const Color8 * restrict srcptr;
                        BB_GET_PIXEL(src, sbb_rotation, Color8, o_x, o_y, &srcptr);
                        dstptr->a = dither_o8x8(o_x, o_y, srcptr->a);
                    }
                }
            }
            break;
        case TYPE_BB8A:
            if (sbb_rotation == 0 && dbb_rotation == 0) {
                dither_lut = dither_o8x8_get_lut();
                for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                    Color8 * restrict dstp = (Color8 *) (dst->data + dst->stride*d_y) + dest_x;
                    const Color8A * restrict srcp = (const Color8A *) (src->data + src->stride*o_y) + offs_x;
                    const unsigned int row_phase = (o_y & 7U) << 3U;
                    unsigned int col_phase = offs_x & 7U;
                    for (unsigned int x = 0; x < w; x++) {
                        dstp[x].a = dither_lut[row_phase + col_phase][srcp[x].a];
                        col_phase = (col_phase + 1U) & 7U;
                    }
                }
            } else {
                for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                    for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                        Color8 * restrict dstptr;
                        BB_GET_PIXEL(dst, dbb_rotation, Color8, d_x, d_y, &dstptr);
                        const Color8A * restrict srcptr;
                        BB_GET_PIXEL(src, sbb_rotation, Color8A, o_x, o_y, &srcptr);
                        dstptr->a = dither_o8x8(o_x, o_y, srcptr->a);
                    }
                }
            }
            break;
        case TYPE_BBRGB16:
            if (sbb_rotation == 0 && dbb_rotation == 0) {
                dither_lut = dither_o8x8_get_lut();
                for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                    Color8 * restrict dstp = (Color8 *) (dst->data + dst->stride*d_y) + dest_x;
                    const ColorRGB16 * restrict srcp = (const ColorRGB16 *) (src->data + src->stride*o_y) + offs_x;
                    const unsigned int row_phase = (o_y & 7U) << 3U;
                    unsigned int col_phase = offs_x & 7U;
                    for (unsigned int x = 0; x < w; x++) {
                        dstp[x].a = dither_lut[row_phase + col_phase][(uint8_t) ColorRGB16_To_A(srcp[x].v)];
                        col_phase = (col_phase + 1U) & 7U;
                    }
                }
            } else {
                for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                    for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                        Color8 * restrict dstptr;
                        BB_GET_PIXEL(dst, dbb_rotation, Color8, d_x, d_y, &dstptr);
                        const ColorRGB16 * restrict srcptr;
                        BB_GET_PIXEL(src, sbb_rotation, ColorRGB16, o_x, o_y, &srcptr);
                        dstptr->a = dither_o8x8(o_x, o_y, (uint8_t) ColorRGB16_To_A(srcptr->v));
                    }
                }
            }
            break;
        case TYPE_BBRGB24:
            if (sbb_rotation == 0 && dbb_rotation == 0) {
                dither_lut = dither_o8x8_get_lut();
                for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                    Color8 * restrict dstp = (Color8 *) (dst->data + dst->stride*d_y) + dest_x;
                    const ColorRGB24 * restrict srcp = (const ColorRGB24 *) (src->data + src->stride*o_y) + offs_x;
                    const unsigned int row_phase = (o_y & 7U) << 3U;
                    unsigned int col_phase = offs_x & 7U;
                    for (unsigned int x = 0; x < w; x++) {
                        dstp[x].a = dither_lut[row_phase + col_phase][(uint8_t) RGB_To_A(srcp[x].r, srcp[x].g, srcp[x].b)];
                        col_phase = (col_phase + 1U) & 7U;
                    }
                }
            } else {
                for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                    for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                        Color8 * restrict dstptr;
                        BB_GET_PIXEL(dst, dbb_rotation, Color8, d_x, d_y, &dstptr);
                        const ColorRGB24 * restrict srcptr;
                        BB_GET_PIXEL(src, sbb_rotation, ColorRGB24, o_x, o_y, &srcptr);
                        dstptr->a = dither_o8x8(o_x, o_y, (uint8_t) RGB_To_A(srcptr->r, srcptr->g, srcptr->b));
                    }
                }
            }
            break;
        case TYPE_BBRGB32:
            if (sbb_rotation == 0 && dbb_rotation == 0) {
                dither_lut = dither_o8x8_get_lut();
                for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                    Color8 * restrict dstp = (Color8 *) (dst->data + dst->stride*d_y) + dest_x;
                    const ColorRGB32 * restrict srcp = (const ColorRGB32 *) (src->data + src->stride*o_y) + offs_x;
                    const unsigned int row_phase = (o_y & 7U) << 3U;
                    BB_dither_rgb32_to_bb8_row(dstp, srcp, w, row_phase, offs_x & 7U, dither_lut);
                }
            } else {
                for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                    for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                        Color8 * restrict dstptr;
                        BB_GET_PIXEL(dst, dbb_rotation, Color8, d_x, d_y, &dstptr);
                        const ColorRGB32 * restrict srcptr;
                        BB_GET_PIXEL(src, sbb_rotation, ColorRGB32, o_x, o_y, &srcptr);
                        dstptr->a = dither_o8x8(o_x, o_y, (uint8_t) RGB_To_A(srcptr->r, srcptr->g, srcptr->b));
                    }
                }
            }
            break;
    }
}

void BB_blit_to_BB8A(const BlitBuffer * restrict src, BlitBuffer * restrict dst,
        unsigned int dest_x, unsigned int dest_y, unsigned int offs_x, unsigned int offs_y, unsigned int w, unsigned int h) {
    const int sbb_type = GET_BB_TYPE(src);
    const int sbb_rotation = GET_BB_ROTATION(src);
    const int dbb_rotation = GET_BB_ROTATION(dst);
    switch (sbb_type) {
        case TYPE_BB8:
            if (sbb_rotation == 0 && dbb_rotation == 0) {
                for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                    Color8A * restrict dstp = (Color8A *) (dst->data + dst->stride*d_y) + dest_x;
                    const Color8 * restrict srcp = (const Color8 *) (src->data + src->stride*o_y) + offs_x;
                    for (unsigned int x = 0; x < w; x++) {
                        dstp[x].a = srcp[x].a;
                    }
                }
            } else {
                for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                    for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                        Color8A * restrict dstptr;
                        BB_GET_PIXEL(dst, dbb_rotation, Color8A, d_x, d_y, &dstptr);
                        const Color8 * restrict srcptr;
                        BB_GET_PIXEL(src, sbb_rotation, Color8, o_x, o_y, &srcptr);
                        dstptr->a = srcptr->a;
                    }
                }
            }
            break;
        case TYPE_BB8A:
            if (sbb_rotation == 0 && dbb_rotation == 0) {
                const uint8_t * restrict srcp = src->data + src->stride*offs_y + (offs_x << 1U);
                uint8_t * restrict dstp = dst->data + dst->stride*dest_y + (dest_x << 1U);
                BB_copy_rows(dstp, dst->stride, srcp, src->stride, w << 1U, h);
            } else {
                for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                    for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                        Color8A * restrict dstptr;
                        BB_GET_PIXEL(dst, dbb_rotation, Color8A, d_x, d_y, &dstptr);
                        const Color8A * restrict srcptr;
                        BB_GET_PIXEL(src, sbb_rotation, Color8A, o_x, o_y, &srcptr);
                        *dstptr = *srcptr;
                    }
                }
            }
            break;
        case TYPE_BBRGB16:
            for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                    Color8A * restrict dstptr;
                    BB_GET_PIXEL(dst, dbb_rotation, Color8A, d_x, d_y, &dstptr);
                    const ColorRGB16 * restrict srcptr;
                    BB_GET_PIXEL(src, sbb_rotation, ColorRGB16, o_x, o_y, &srcptr);
                    dstptr->a = (uint8_t) ColorRGB16_To_A(srcptr->v);
                }
            }
            break;
        case TYPE_BBRGB24:
            for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                    Color8A * restrict dstptr;
                    BB_GET_PIXEL(dst, dbb_rotation, Color8A, d_x, d_y, &dstptr);
                    const ColorRGB24 * restrict srcptr;
                    BB_GET_PIXEL(src, sbb_rotation, ColorRGB24, o_x, o_y, &srcptr);
                    dstptr->a = (uint8_t) RGB_To_A(srcptr->r, srcptr->g, srcptr->b);
                }
            }
            break;
        case TYPE_BBRGB32:
            for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                    Color8A * restrict dstptr;
                    BB_GET_PIXEL(dst, dbb_rotation, Color8A, d_x, d_y, &dstptr);
                    const ColorRGB32 * restrict srcptr;
                    BB_GET_PIXEL(src, sbb_rotation, ColorRGB32, o_x, o_y, &srcptr);
                    dstptr->a = (uint8_t) RGB_To_A(srcptr->r, srcptr->g, srcptr->b);
                }
            }
            break;
    }
}

void BB_blit_to_BB16(const BlitBuffer * restrict src, BlitBuffer * restrict dst,
        unsigned int dest_x, unsigned int dest_y, unsigned int offs_x, unsigned int offs_y, unsigned int w, unsigned int h) {
    const int sbb_type = GET_BB_TYPE(src);
    const int sbb_rotation = GET_BB_ROTATION(src);
    const int dbb_rotation = GET_BB_ROTATION(dst);
    switch (sbb_type) {
        case TYPE_BB8:
            for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                    ColorRGB16 * restrict dstptr;
                    BB_GET_PIXEL(dst, dbb_rotation, ColorRGB16, d_x, d_y, &dstptr);
                    const Color8 * restrict srcptr;
                    BB_GET_PIXEL(src, sbb_rotation, Color8, o_x, o_y, &srcptr);
                    const uint8_t v = srcptr->a;
                    const uint8_t v5bit = v >> 3U;
                    dstptr->v = (uint16_t) ((v5bit << 11U) + ((v & 0xFC) << 3U) + v5bit);
                }
            }
            break;
        case TYPE_BB8A:
            for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                    ColorRGB16 * restrict dstptr;
                    BB_GET_PIXEL(dst, dbb_rotation, ColorRGB16, d_x, d_y, &dstptr);
                    const Color8A * restrict srcptr;
                    BB_GET_PIXEL(src, sbb_rotation, Color8A, o_x, o_y, &srcptr);
                    const uint8_t v = srcptr->a;
                    const uint8_t v5bit = v >> 3U;
                    dstptr->v = (uint16_t) ((v5bit << 11U) + ((v & 0xFC) << 3U) + v5bit);
                }
            }
            break;
        case TYPE_BBRGB16:
            for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                    ColorRGB16 * restrict dstptr;
                    BB_GET_PIXEL(dst, dbb_rotation, ColorRGB16, d_x, d_y, &dstptr);
                    const ColorRGB16 * restrict srcptr;
                    BB_GET_PIXEL(src, sbb_rotation, ColorRGB16, o_x, o_y, &srcptr);
                    *dstptr = *srcptr;
                }
            }
            break;
        case TYPE_BBRGB24:
            for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                    ColorRGB16 * restrict dstptr;
                    BB_GET_PIXEL(dst, dbb_rotation, ColorRGB16, d_x, d_y, &dstptr);
                    const ColorRGB24 * restrict srcptr;
                    BB_GET_PIXEL(src, sbb_rotation, ColorRGB24, o_x, o_y, &srcptr);
                    dstptr->v = (uint16_t) RGB_To_RGB16(srcptr->r, srcptr->g, srcptr->b);
                }
            }
            break;
        case TYPE_BBRGB32:
            for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                    ColorRGB16 * restrict dstptr;
                    BB_GET_PIXEL(dst, dbb_rotation, ColorRGB16, d_x, d_y, &dstptr);
                    const ColorRGB32 * restrict srcptr;
                    BB_GET_PIXEL(src, sbb_rotation, ColorRGB32, o_x, o_y, &srcptr);
                    dstptr->v = (uint16_t) RGB_To_RGB16(srcptr->r, srcptr->g, srcptr->b);
                }
            }
            break;
    }
}

void BB_blit_to_BB24(const BlitBuffer * restrict src, BlitBuffer * restrict dst,
        unsigned int dest_x, unsigned int dest_y, unsigned int offs_x, unsigned int offs_y, unsigned int w, unsigned int h) {
    const int sbb_type = GET_BB_TYPE(src);
    const int sbb_rotation = GET_BB_ROTATION(src);
    const int dbb_rotation = GET_BB_ROTATION(dst);
    switch (sbb_type) {
        case TYPE_BB8:
            for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                    ColorRGB24 * restrict dstptr;
                    BB_GET_PIXEL(dst, dbb_rotation, ColorRGB24, d_x, d_y, &dstptr);
                    const Color8 * restrict srcptr;
                    BB_GET_PIXEL(src, sbb_rotation, Color8, o_x, o_y, &srcptr);
                    dstptr->r = srcptr->a;
                    dstptr->g = srcptr->a;
                    dstptr->b = srcptr->a;
                }
            }
            break;
        case TYPE_BB8A:
            for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                    ColorRGB24 * restrict dstptr;
                    BB_GET_PIXEL(dst, dbb_rotation, ColorRGB24, d_x, d_y, &dstptr);
                    const Color8A * restrict srcptr;
                    BB_GET_PIXEL(src, sbb_rotation, Color8A, o_x, o_y, &srcptr);
                    dstptr->r = srcptr->a;
                    dstptr->g = srcptr->a;
                    dstptr->b = srcptr->a;
                }
            }
            break;
        case TYPE_BBRGB16:
            for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                    ColorRGB24 * restrict dstptr;
                    BB_GET_PIXEL(dst, dbb_rotation, ColorRGB24, d_x, d_y, &dstptr);
                    const ColorRGB16 * restrict srcptr;
                    BB_GET_PIXEL(src, sbb_rotation, ColorRGB16, o_x, o_y, &srcptr);
                    dstptr->r = (uint8_t) ColorRGB16_GetR(srcptr->v);
                    dstptr->g = (uint8_t) ColorRGB16_GetG(srcptr->v);
                    dstptr->b = (uint8_t) ColorRGB16_GetB(srcptr->v);
                }
            }
            break;
        case TYPE_BBRGB24:
            for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                    ColorRGB24 * restrict dstptr;
                    BB_GET_PIXEL(dst, dbb_rotation, ColorRGB24, d_x, d_y, &dstptr);
                    const ColorRGB24 * restrict srcptr;
                    BB_GET_PIXEL(src, sbb_rotation, ColorRGB24, o_x, o_y, &srcptr);
                    *dstptr = *srcptr;
                }
            }
            break;
        case TYPE_BBRGB32:
            for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                    ColorRGB24 * restrict dstptr;
                    BB_GET_PIXEL(dst, dbb_rotation, ColorRGB24, d_x, d_y, &dstptr);
                    const ColorRGB32 * restrict srcptr;
                    BB_GET_PIXEL(src, sbb_rotation, ColorRGB32, o_x, o_y, &srcptr);
                    dstptr->r = srcptr->r;
                    dstptr->g = srcptr->g;
                    dstptr->b = srcptr->b;
                }
            }
            break;
    }
}

void BB_blit_to_BB32(const BlitBuffer * restrict src, BlitBuffer * restrict dst,
        unsigned int dest_x, unsigned int dest_y, unsigned int offs_x, unsigned int offs_y, unsigned int w, unsigned int h) {
    const int sbb_type = GET_BB_TYPE(src);
    const int sbb_rotation = GET_BB_ROTATION(src);
    const int dbb_rotation = GET_BB_ROTATION(dst);
    switch (sbb_type) {
        case TYPE_BB8:
            if (sbb_rotation == 0 && dbb_rotation == 0) {
                for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                    uint32_t * restrict dstp = (uint32_t *) (dst->data + dst->stride*d_y) + dest_x;
                    const Color8 * restrict srcp = (const Color8 *) (src->data + src->stride*o_y) + offs_x;
                    BB_y8_to_rgb32_row(dstp, srcp, w);
                }
            } else {
                for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                    for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                        ColorRGB32 * restrict dstptr;
                        BB_GET_PIXEL(dst, dbb_rotation, ColorRGB32, d_x, d_y, &dstptr);
                        const Color8 * restrict srcptr;
                        BB_GET_PIXEL(src, sbb_rotation, Color8, o_x, o_y, &srcptr);
                        dstptr->r = srcptr->a;
                        dstptr->g = srcptr->a;
                        dstptr->b = srcptr->a;
                        dstptr->alpha = 0xFF;
                    }
                }
            }
            break;
        case TYPE_BB8A:
            if (sbb_rotation == 0 && dbb_rotation == 0) {
                for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                    uint32_t * restrict dstp = (uint32_t *) (dst->data + dst->stride*d_y) + dest_x;
                    const Color8A * restrict srcp = (const Color8A *) (src->data + src->stride*o_y) + offs_x;
                    BB_y8a_to_rgb32_row(dstp, srcp, w);
                }
            } else {
                for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                    for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                        ColorRGB32 * restrict dstptr;
                        BB_GET_PIXEL(dst, dbb_rotation, ColorRGB32, d_x, d_y, &dstptr);
                        const Color8A * restrict srcptr;
                        BB_GET_PIXEL(src, sbb_rotation, Color8A, o_x, o_y, &srcptr);
                        dstptr->r = srcptr->a;
                        dstptr->g = srcptr->a;
                        dstptr->b = srcptr->a;
                        dstptr->alpha = srcptr->alpha; // if bad result, try: srcptr->alpha ^ 0xFF
                    }
                }
            }
            break;
        case TYPE_BBRGB16:
            for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                    ColorRGB32 * restrict dstptr;
                    BB_GET_PIXEL(dst, dbb_rotation, ColorRGB32, d_x, d_y, &dstptr);
                    const ColorRGB16 * restrict srcptr;
                    BB_GET_PIXEL(src, sbb_rotation, ColorRGB16, o_x, o_y, &srcptr);
                    dstptr->r = (uint8_t) ColorRGB16_GetR(srcptr->v);
                    dstptr->g = (uint8_t) ColorRGB16_GetG(srcptr->v);
                    dstptr->b = (uint8_t) ColorRGB16_GetB(srcptr->v);
                    dstptr->alpha = 0xFF;
                }
            }
            break;
        case TYPE_BBRGB24:
            for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                    ColorRGB32 * restrict dstptr;
                    BB_GET_PIXEL(dst, dbb_rotation, ColorRGB32, d_x, d_y, &dstptr);
                    const ColorRGB24 * restrict srcptr;
                    BB_GET_PIXEL(src, sbb_rotation, ColorRGB24, o_x, o_y, &srcptr);
                    dstptr->r = srcptr->r;
                    dstptr->g = srcptr->g;
                    dstptr->b = srcptr->b;
                    dstptr->alpha = 0xFF;
                }
            }
            break;
        case TYPE_BBRGB32:
            // We can only do a fast copy for simple same-to-same blitting without any extra processing.
            // (i.e., setPixel, no rota, no invert).
            // The cbb codepath ensures setPixel & no invert, so we only check for rotation.
            if (sbb_rotation == 0 && dbb_rotation == 0) {
                if (offs_x == 0 && dest_x == 0 && w == src->w && w == dst->w && src->stride == dst->stride) {
                    // BBRGB32 is 4 bytes per pixel.
                    const uint8_t * restrict srcp = src->data + src->stride*offs_y;
                    uint8_t * restrict dstp = dst->data + dst->stride*dest_y;
                    BB_copy_rows(dstp, dst->stride, srcp, src->stride, w << 2U, h);
                } else {
                    // Scanline per scanline copy
                    //fprintf(stdout, "%s: scanline copy blit from BBRGB32 to BBRGB32\n", __FUNCTION__);
                    for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y+h; d_y++, o_y++) {
                        // BBRGB32 is 4 bytes per pixel
                        const uint8_t * restrict srcp = src->data + src->stride*o_y + (offs_x << 2);
                        uint8_t * restrict dstp = dst->data + dst->stride*d_y + (dest_x << 2);
                        memcpy(dstp, srcp, w << 2U);
                    }
                }
            } else {
                for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                    for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                        ColorRGB32 * restrict dstptr;
                        BB_GET_PIXEL(dst, dbb_rotation, ColorRGB32, d_x, d_y, &dstptr);
                        const ColorRGB32 * restrict srcptr;
                        BB_GET_PIXEL(src, sbb_rotation, ColorRGB32, o_x, o_y, &srcptr);
                        *dstptr = *srcptr;
                    }
                }
            }
            break;
    }
}

void BB_blit_to(const BlitBuffer * restrict src, BlitBuffer * restrict dst,
        unsigned int dest_x, unsigned int dest_y, unsigned int offs_x, unsigned int offs_y, unsigned int w, unsigned int h) {
    const int dbb_type = GET_BB_TYPE(dst);
    //fprintf(stdout, "%s: blit from type: %s to: %s\n", __FUNCTION__, get_bbtype_name(GET_BB_TYPE(src)), get_bbtype_name(GET_BB_TYPE(dst)));
    switch (dbb_type) {
        case TYPE_BB8:
            return BB_blit_to_BB8(src, dst, dest_x, dest_y, offs_x, offs_y, w, h);
        case TYPE_BB8A:
            return BB_blit_to_BB8A(src, dst, dest_x, dest_y, offs_x, offs_y, w, h);
        case TYPE_BBRGB16:
            return BB_blit_to_BB16(src, dst, dest_x, dest_y, offs_x, offs_y, w, h);
        case TYPE_BBRGB24:
            return BB_blit_to_BB24(src, dst, dest_x, dest_y, offs_x, offs_y, w, h);
        case TYPE_BBRGB32:
            return BB_blit_to_BB32(src, dst, dest_x, dest_y, offs_x, offs_y, w, h);
    }
}

// Only actually honors dithering when blitting to BB8 ;).
void BB_dither_blit_to(const BlitBuffer * restrict src, BlitBuffer * restrict dst,
        unsigned int dest_x, unsigned int dest_y, unsigned int offs_x, unsigned int offs_y, unsigned int w, unsigned int h) {
    const int dbb_type = GET_BB_TYPE(dst);
    //fprintf(stdout, "%s: dither blit from type: %s to: %s\n", __FUNCTION__, get_bbtype_name(GET_BB_TYPE(src)), get_bbtype_name(GET_BB_TYPE(dst)));
    switch (dbb_type) {
        case TYPE_BB8:
            return BB_dither_blit_to_BB8(src, dst, dest_x, dest_y, offs_x, offs_y, w, h);
        case TYPE_BB8A:
            return BB_blit_to_BB8A(src, dst, dest_x, dest_y, offs_x, offs_y, w, h);
        case TYPE_BBRGB16:
            return BB_blit_to_BB16(src, dst, dest_x, dest_y, offs_x, offs_y, w, h);
        case TYPE_BBRGB24:
            return BB_blit_to_BB24(src, dst, dest_x, dest_y, offs_x, offs_y, w, h);
        case TYPE_BBRGB32:
            return BB_blit_to_BB32(src, dst, dest_x, dest_y, offs_x, offs_y, w, h);
    }
}

void BB_add_blit_from(BlitBuffer * restrict dst, const BlitBuffer * restrict src,
        unsigned int dest_x, unsigned int dest_y, unsigned int offs_x, unsigned int offs_y, unsigned int w, unsigned int h,
        uint8_t alpha) {
    // fast paths
    if (alpha == 0) {
        // NOP
        return;
    } else if (alpha == 0xFF) {
        return BB_blit_to(src, dst, dest_x, dest_y, offs_x, offs_y, w, h);
    }

    const int dbb_type = GET_BB_TYPE(dst);
    const int sbb_type = GET_BB_TYPE(src);
    const int sbb_rotation = GET_BB_ROTATION(src);
    const int dbb_rotation = GET_BB_ROTATION(dst);
    if (dbb_type != sbb_type) {
        fprintf(stderr, "%s: incompatible bb (dst: %s, src: %s) in file %s, line %d!\n",
                __FUNCTION__, get_bbtype_name(dbb_type), get_bbtype_name(sbb_type), __FILE__, __LINE__);
        exit(1);
    }
    const uint8_t ainv = alpha ^ 0xFF;
    switch (dbb_type) {
        case TYPE_BB8:
            for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                    Color8 * restrict dstptr;
                    BB_GET_PIXEL(dst, dbb_rotation, Color8, d_x, d_y, &dstptr);
                    const Color8 * restrict srcptr;
                    BB_GET_PIXEL(src, sbb_rotation, Color8, o_x, o_y, &srcptr);
                    dstptr->a = (uint8_t) DIV_255(dstptr->a * ainv + srcptr->a * alpha);
                }
            }
            break;
        case TYPE_BB8A:
            for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                    Color8A * restrict dstptr;
                    BB_GET_PIXEL(dst, dbb_rotation, Color8A, d_x, d_y, &dstptr);
                    const Color8A * restrict srcptr;
                    BB_GET_PIXEL(src, sbb_rotation, Color8A, o_x, o_y, &srcptr);
                    dstptr->a = (uint8_t) DIV_255(dstptr->a * ainv + srcptr->a * alpha);
                }
            }
            break;
        case TYPE_BBRGB16:
            for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                    ColorRGB16 * restrict dstptr;
                    BB_GET_PIXEL(dst, dbb_rotation, ColorRGB16, d_x, d_y, &dstptr);
                    const ColorRGB16 * restrict srcptr;
                    BB_GET_PIXEL(src, sbb_rotation, ColorRGB16, o_x, o_y, &srcptr);
                    const uint8_t r = (uint8_t) DIV_255(ColorRGB16_GetR(dstptr->v) * ainv + ColorRGB16_GetR(srcptr->v) * alpha);
                    const uint8_t g = (uint8_t) DIV_255(ColorRGB16_GetG(dstptr->v) * ainv + ColorRGB16_GetG(srcptr->v) * alpha);
                    const uint8_t b = (uint8_t) DIV_255(ColorRGB16_GetB(dstptr->v) * ainv + ColorRGB16_GetB(srcptr->v) * alpha);
                    dstptr->v = (uint16_t) RGB_To_RGB16(r, g, b);
                }
            }
            break;
        case TYPE_BBRGB24:
            for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                    ColorRGB24 * restrict dstptr;
                    BB_GET_PIXEL(dst, dbb_rotation, ColorRGB24, d_x, d_y, &dstptr);
                    const ColorRGB24 * restrict srcptr;
                    BB_GET_PIXEL(src, sbb_rotation, ColorRGB24, o_x, o_y, &srcptr);
                    dstptr->r = (uint8_t) DIV_255(dstptr->r * ainv + srcptr->r * alpha);
                    dstptr->g = (uint8_t) DIV_255(dstptr->g * ainv + srcptr->g * alpha);
                    dstptr->b = (uint8_t) DIV_255(dstptr->b * ainv + srcptr->b * alpha);
                }
            }
            break;
        case TYPE_BBRGB32:
            for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                    ColorRGB32 * restrict dstptr;
                    BB_GET_PIXEL(dst, dbb_rotation, ColorRGB32, d_x, d_y, &dstptr);
                    const ColorRGB32 * restrict srcptr;
                    BB_GET_PIXEL(src, sbb_rotation, ColorRGB32, o_x, o_y, &srcptr);
                    dstptr->r = (uint8_t) DIV_255(dstptr->r * ainv + srcptr->r * alpha);
                    dstptr->g = (uint8_t) DIV_255(dstptr->g * ainv + srcptr->g * alpha);
                    dstptr->b = (uint8_t) DIV_255(dstptr->b * ainv + srcptr->b * alpha);
                }
            }
            break;
    }
}

void BB_alpha_blit_from(BlitBuffer * restrict dst, const BlitBuffer * restrict src,
        unsigned int dest_x, unsigned int dest_y, unsigned int offs_x, unsigned int offs_y, unsigned int w, unsigned int h) {
    const int dbb_type = GET_BB_TYPE(dst);
    const int sbb_type = GET_BB_TYPE(src);
    const int sbb_rotation = GET_BB_ROTATION(src);
    const int dbb_rotation = GET_BB_ROTATION(dst);
    switch (dbb_type) {
        case TYPE_BB8:
            switch (sbb_type) {
                case TYPE_BB8:
                    for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                        for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                            Color8 * restrict dstptr;
                            BB_GET_PIXEL(dst, dbb_rotation, Color8, d_x, d_y, &dstptr);
                            const Color8 * restrict srcptr;
                            BB_GET_PIXEL(src, sbb_rotation, Color8, o_x, o_y, &srcptr);
                            *dstptr = *srcptr;
                        }
                }
                break;
            case TYPE_BB8A:
                    if (sbb_rotation == 0 && dbb_rotation == 0) {
                        for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                            Color8 * restrict dstp = (Color8 *) (dst->data + dst->stride*d_y) + dest_x;
                            const Color8A * restrict srcp = (const Color8A *) (src->data + src->stride*o_y) + offs_x;
                            BB_bb8a_alpha_to_bb8_row(dstp, srcp, w);
                        }
                    } else {
                        for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                            for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                                const Color8A * restrict srcptr;
                                BB_GET_PIXEL(src, sbb_rotation, Color8A, o_x, o_y, &srcptr);
                                const uint8_t alpha = srcptr->alpha;
                                if (alpha == 0) {
                                    // NOP
                                } else if (alpha == 0xFF) {
                                    Color8 * restrict dstptr;
                                    BB_GET_PIXEL(dst, dbb_rotation, Color8, d_x, d_y, &dstptr);
                                    dstptr->a = srcptr->a;
                                } else {
                                    const uint8_t ainv = alpha ^ 0xFF;
                                    Color8 * restrict dstptr;
                                    BB_GET_PIXEL(dst, dbb_rotation, Color8, d_x, d_y, &dstptr);
                                    dstptr->a = (uint8_t) DIV_255(dstptr->a * ainv + srcptr->a * alpha);
                                }
                            }
                        }
                    }
                    break;
                case TYPE_BBRGB16:
                    for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                        for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                            Color8 * restrict dstptr;
                            BB_GET_PIXEL(dst, dbb_rotation, Color8, d_x, d_y, &dstptr);
                            const ColorRGB16 * restrict srcptr;
                            BB_GET_PIXEL(src, sbb_rotation, ColorRGB16, o_x, o_y, &srcptr);
                            dstptr->a = (uint8_t) ColorRGB16_To_A(srcptr->v);
                        }
                    }
                    break;
                case TYPE_BBRGB24:
                    for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                        for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                            Color8 * restrict dstptr;
                            BB_GET_PIXEL(dst, dbb_rotation, Color8, d_x, d_y, &dstptr);
                            const ColorRGB24 * restrict srcptr;
                            BB_GET_PIXEL(src, sbb_rotation, ColorRGB24, o_x, o_y, &srcptr);
                            dstptr->a = (uint8_t) RGB_To_A(srcptr->r, srcptr->g, srcptr->b);
                        }
                }
                break;
            case TYPE_BBRGB32:
                    if (sbb_rotation == 0 && dbb_rotation == 0) {
                        for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                            Color8 * restrict dstp = (Color8 *) (dst->data + dst->stride*d_y) + dest_x;
                            const ColorRGB32 * restrict srcp = (const ColorRGB32 *) (src->data + src->stride*o_y) + offs_x;
                            BB_rgb32_alpha_to_bb8_row(dstp, srcp, w);
                        }
                    } else {
                        for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                            for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                                const ColorRGB32 * restrict srcptr;
                                BB_GET_PIXEL(src, sbb_rotation, ColorRGB32, o_x, o_y, &srcptr);
                                const uint8_t alpha = srcptr->alpha;
                                if (alpha == 0) {
                                    // NOP
                                } else if (alpha == 0xFF) {
                                    Color8 * restrict dstptr;
                                    BB_GET_PIXEL(dst, dbb_rotation, Color8, d_x, d_y, &dstptr);
                                    dstptr->a = (uint8_t) RGB_To_A(srcptr->r, srcptr->g, srcptr->b);
                                } else {
                                    const uint8_t ainv = alpha ^ 0xFF;
                                    const uint8_t srca = (uint8_t) RGB_To_A(srcptr->r, srcptr->g, srcptr->b);
                                    Color8 * restrict dstptr;
                                    BB_GET_PIXEL(dst, dbb_rotation, Color8, d_x, d_y, &dstptr);
                                    dstptr->a = (uint8_t) DIV_255(dstptr->a * ainv + srca * alpha);
                                }
                            }
                        }
                    }
                    break;
                default:
                    fprintf(stderr, "%s: incompatible bb (dst: BB8, src: %s) in file %s, line %d!\n",
                            __FUNCTION__, get_bbtype_name(sbb_type), __FILE__, __LINE__);
                    exit(1);
                    break;
            }
            break;
        case TYPE_BB8A:
            switch (sbb_type) {
                case TYPE_BB8A:
                    for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                        for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                            const Color8A * restrict srcptr;
                            BB_GET_PIXEL(src, sbb_rotation, Color8A, o_x, o_y, &srcptr);
                            const uint8_t alpha = srcptr->alpha;
                            if (alpha == 0) {
                                // NOP
                            } else if (alpha == 0xFF) {
                                Color8A * restrict dstptr;
                                BB_GET_PIXEL(dst, dbb_rotation, Color8A, d_x, d_y, &dstptr);
                                *dstptr = *srcptr;
                            } else {
                                const uint8_t ainv = alpha ^ 0xFF;
                                Color8A * restrict dstptr;
                                BB_GET_PIXEL(dst, dbb_rotation, Color8A, d_x, d_y, &dstptr);
                                dstptr->a = (uint8_t) DIV_255(dstptr->a * ainv + srcptr->a * alpha);
                            }
                        }
                    }
                    break;
                default:
                    fprintf(stderr, "%s: incompatible bb (dst: BB8A, src: %s) in file %s, line %d!\n",
                            __FUNCTION__, get_bbtype_name(sbb_type), __FILE__, __LINE__);
                    exit(1);
                    break;
            }
            break;
        case TYPE_BBRGB16:
            switch (sbb_type) {
                case TYPE_BB8:
                    for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                        for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                            ColorRGB16 * restrict dstptr;
                            BB_GET_PIXEL(dst, dbb_rotation, ColorRGB16, d_x, d_y, &dstptr);
                            const Color8 * restrict srcptr;
                            BB_GET_PIXEL(src, sbb_rotation, Color8, o_x, o_y, &srcptr);
                            dstptr->v = (uint16_t) RGB_To_RGB16(srcptr->a, srcptr->a, srcptr->a);
                        }
                    }
                    break;
                case TYPE_BB8A:
                    for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                        for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                            const Color8A * restrict srcptr;
                            BB_GET_PIXEL(src, sbb_rotation, Color8A, o_x, o_y, &srcptr);
                            const uint8_t alpha = srcptr->alpha;
                            if (alpha == 0) {
                                // NOP
                            } else if (alpha == 0xFF) {
                                ColorRGB16 * restrict dstptr;
                                BB_GET_PIXEL(dst, dbb_rotation, ColorRGB16, d_x, d_y, &dstptr);
                                dstptr->v = (uint16_t) RGB_To_RGB16(srcptr->a, srcptr->a, srcptr->a);
                            } else {
                                const uint8_t ainv = alpha ^ 0xFF;
                                ColorRGB16 * restrict dstptr;
                                BB_GET_PIXEL(dst, dbb_rotation, ColorRGB16, d_x, d_y, &dstptr);
                                const uint8_t dsta = (uint8_t) ColorRGB16_To_A(dstptr->v);
                                const uint8_t bdsta = (uint8_t) DIV_255(dsta * ainv + srcptr->a * alpha);
                                dstptr->v = (uint16_t) RGB_To_RGB16(bdsta, bdsta, bdsta);
                            }
                        }
                    }
                    break;
                case TYPE_BBRGB16:
                    for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                        for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                            ColorRGB16 * restrict dstptr;
                            BB_GET_PIXEL(dst, dbb_rotation, ColorRGB16, d_x, d_y, &dstptr);
                            const ColorRGB16 * restrict srcptr;
                            BB_GET_PIXEL(src, sbb_rotation, ColorRGB16, o_x, o_y, &srcptr);
                            *dstptr = *srcptr;
                        }
                    }
                    break;
                case TYPE_BBRGB24:
                    for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                        for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                            ColorRGB16 * restrict dstptr;
                            BB_GET_PIXEL(dst, dbb_rotation, ColorRGB16, d_x, d_y, &dstptr);
                            const ColorRGB24 * restrict srcptr;
                            BB_GET_PIXEL(src, sbb_rotation, ColorRGB24, o_x, o_y, &srcptr);
                            dstptr->v = (uint16_t) RGB_To_RGB16(srcptr->r, srcptr->g, srcptr->b);
                        }
                    }
                    break;
                case TYPE_BBRGB32:
                    for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                        for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                            const ColorRGB32 * restrict srcptr;
                            BB_GET_PIXEL(src, sbb_rotation, ColorRGB32, o_x, o_y, &srcptr);
                            const uint8_t alpha = srcptr->alpha;
                            if (alpha == 0) {
                                // NOP
                            } else if (alpha == 0xFF) {
                                ColorRGB16 * restrict dstptr;
                                BB_GET_PIXEL(dst, dbb_rotation, ColorRGB16, d_x, d_y, &dstptr);
                                dstptr->v = (uint16_t) RGB_To_RGB16(srcptr->r, srcptr->g, srcptr->b);
                            } else {
                                const uint8_t ainv = alpha ^ 0xFF;
                                ColorRGB16 * restrict dstptr;
                                BB_GET_PIXEL(dst, dbb_rotation, ColorRGB16, d_x, d_y, &dstptr);
                                const uint8_t r = (uint8_t) DIV_255(ColorRGB16_GetR(dstptr->v) * ainv + srcptr->r * alpha);
                                const uint8_t g = (uint8_t) DIV_255(ColorRGB16_GetG(dstptr->v) * ainv + srcptr->g * alpha);
                                const uint8_t b = (uint8_t) DIV_255(ColorRGB16_GetB(dstptr->v) * ainv + srcptr->b * alpha);
                                dstptr->v = (uint16_t) RGB_To_RGB16(r, g, b);
                            }
                        }
                    }
                    break;
                default:
                    fprintf(stderr, "%s: incompatible bb (dst: BBRGB16, src: %s) in file %s, line %d!\n",
                            __FUNCTION__, get_bbtype_name(sbb_type), __FILE__, __LINE__);
                    exit(1);
                    break;
            }
            break;
        case TYPE_BBRGB24:
            switch (sbb_type) {
                case TYPE_BBRGB24:
                    for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                        for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                            ColorRGB24 * restrict dstptr;
                            BB_GET_PIXEL(dst, dbb_rotation, ColorRGB24, d_x, d_y, &dstptr);
                            const ColorRGB24 * restrict srcptr;
                            BB_GET_PIXEL(src, sbb_rotation, ColorRGB24, o_x, o_y, &srcptr);
                            *dstptr = *srcptr;
                        }
                    }
                    break;
                default:
                    fprintf(stderr, "%s: incompatible bb (dst: BBRGB24, src: %s) in file %s, line %d!\n",
                            __FUNCTION__, get_bbtype_name(sbb_type), __FILE__, __LINE__);
                    exit(1);
                    break;
            }
            break;
        case TYPE_BBRGB32:
            switch (sbb_type) {
                case TYPE_BB8:
                    for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                        for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                            ColorRGB32 * restrict dstptr;
                            BB_GET_PIXEL(dst, dbb_rotation, ColorRGB32, d_x, d_y, &dstptr);
                            const Color8 * restrict srcptr;
                            BB_GET_PIXEL(src, sbb_rotation, Color8, o_x, o_y, &srcptr);
                            dstptr->r = srcptr->a;
                            dstptr->g = srcptr->a;
                            dstptr->b = srcptr->a;
                            //dstptr->alpha = dstptr->alpha;
                        }
                    }
                    break;
                case TYPE_BB8A:
                    for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                        for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                            const Color8A * restrict srcptr;
                            BB_GET_PIXEL(src, sbb_rotation, Color8A, o_x, o_y, &srcptr);
                            const uint8_t alpha = srcptr->alpha;
                            if (alpha == 0) {
                                // NOP
                            } else if (alpha == 0xFF) {
                                ColorRGB32 * restrict dstptr;
                                BB_GET_PIXEL(dst, dbb_rotation, ColorRGB32, d_x, d_y, &dstptr);
                                dstptr->r = srcptr->a;
                                dstptr->g = srcptr->a;
                                dstptr->b = srcptr->a;
                                //dstptr->alpha = srcptr->alpha;
                            } else {
                                const uint8_t ainv = alpha ^ 0xFF;
                                ColorRGB32 * restrict dstptr;
                                BB_GET_PIXEL(dst, dbb_rotation, ColorRGB32, d_x, d_y, &dstptr);
                                const uint8_t dsta = (uint8_t) RGB_To_A(dstptr->r, dstptr->g, dstptr->b);
                                const uint8_t bdsta = (uint8_t) DIV_255(dsta * ainv + srcptr->a * alpha);
                                dstptr->r = bdsta;
                                dstptr->g = bdsta;
                                dstptr->b = bdsta;
                                //dstptr->alpha = dstptr->alpha;
                            }
                        }
                    }
                    break;
                case TYPE_BBRGB16:
                    for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                        for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                            ColorRGB32 * restrict dstptr;
                            BB_GET_PIXEL(dst, dbb_rotation, ColorRGB32, d_x, d_y, &dstptr);
                            const ColorRGB16 * restrict srcptr;
                            BB_GET_PIXEL(src, sbb_rotation, ColorRGB16, o_x, o_y, &srcptr);
                            dstptr->r = (uint8_t) ColorRGB16_GetR(srcptr->v);
                            dstptr->g = (uint8_t) ColorRGB16_GetG(srcptr->v);
                            dstptr->b = (uint8_t) ColorRGB16_GetB(srcptr->v);
                            //dstptr->alpha = dstptr->alpha;
                        }
                    }
                    break;
                case TYPE_BBRGB24:
                    for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                        for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                            ColorRGB32 * restrict dstptr;
                            BB_GET_PIXEL(dst, dbb_rotation, ColorRGB32, d_x, d_y, &dstptr);
                            const ColorRGB24 * restrict srcptr;
                            BB_GET_PIXEL(src, sbb_rotation, ColorRGB24, o_x, o_y, &srcptr);
                            dstptr->r = srcptr->r;
                            dstptr->g = srcptr->g;
                            dstptr->b = srcptr->b;
                            //dstptr->alpha = dstptr->alpha;
                        }
                    }
                    break;
                case TYPE_BBRGB32:
                    for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                        for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                            const ColorRGB32 * restrict srcptr;
                            BB_GET_PIXEL(src, sbb_rotation, ColorRGB32, o_x, o_y, &srcptr);
                            const uint8_t alpha = srcptr->alpha;
                            if (alpha == 0) {
                                // NOP
                            } else if (alpha == 0xFF) {
                                ColorRGB32 * restrict dstptr;
                                BB_GET_PIXEL(dst, dbb_rotation, ColorRGB32, d_x, d_y, &dstptr);
                                *dstptr = *srcptr;
                            } else {
                                const uint8_t ainv = alpha ^ 0xFF;
                                ColorRGB32 * restrict dstptr;
                                BB_GET_PIXEL(dst, dbb_rotation, ColorRGB32, d_x, d_y, &dstptr);
                                dstptr->r = (uint8_t) DIV_255(dstptr->r * ainv + srcptr->r * alpha);
                                dstptr->g = (uint8_t) DIV_255(dstptr->g * ainv + srcptr->g * alpha);
                                dstptr->b = (uint8_t) DIV_255(dstptr->b * ainv + srcptr->b * alpha);
                                //dstptr->alpha = dstptr->alpha;
                            }
                        }
                    }
                    break;
                default:
                    fprintf(stderr, "%s: incompatible bb (dst: BBRGB32, src: %s) in file %s, line %d!\n",
                            __FUNCTION__, get_bbtype_name(sbb_type), __FILE__, __LINE__);
                    exit(1);
                    break;
            }
            break;
        default:
            fprintf(stderr, "%s: incompatible bb (dst: %s, src: %s) in file %s, line %d!\n",
                    __FUNCTION__, get_bbtype_name(dbb_type), get_bbtype_name(sbb_type), __FILE__, __LINE__);
            exit(1);
            break;
    }
}

// NOTE: Keep in sync w/ BB_alpha_blit_from!
//       Dithering is only honored for BB8 dbb ;).
void BB_dither_alpha_blit_from(BlitBuffer * restrict dst, const BlitBuffer * restrict src,
        unsigned int dest_x, unsigned int dest_y, unsigned int offs_x, unsigned int offs_y, unsigned int w, unsigned int h) {
    const int dbb_type = GET_BB_TYPE(dst);
    const int sbb_type = GET_BB_TYPE(src);
    const int sbb_rotation = GET_BB_ROTATION(src);
    const int dbb_rotation = GET_BB_ROTATION(dst);
    const uint8_t (* restrict dither_lut)[256] = NULL;
    switch (dbb_type) {
        case TYPE_BB8:
            switch (sbb_type) {
                case TYPE_BB8:
                    if (sbb_rotation == 0 && dbb_rotation == 0) {
                        dither_lut = dither_o8x8_get_lut();
                        for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                            Color8 * restrict dstp = (Color8 *) (dst->data + dst->stride*d_y) + dest_x;
                            const Color8 * restrict srcp = (const Color8 *) (src->data + src->stride*o_y) + offs_x;
                            BB_dither_y8_to_bb8_row(dstp, srcp, w, (o_y & 7U) << 3U, offs_x & 7U, dither_lut);
                        }
                    } else {
                        for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                            for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                                Color8 * restrict dstptr;
                                BB_GET_PIXEL(dst, dbb_rotation, Color8, d_x, d_y, &dstptr);
                                const Color8 * restrict srcptr;
                                BB_GET_PIXEL(src, sbb_rotation, Color8, o_x, o_y, &srcptr);
                                dstptr->a = dither_o8x8(o_x, o_y, srcptr->a);
                            }
                        }
                    }
                    break;
                case TYPE_BB8A:
                    if (sbb_rotation == 0 && dbb_rotation == 0) {
                        dither_lut = dither_o8x8_get_lut();
                        for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                            Color8 * restrict dstp = (Color8 *) (dst->data + dst->stride*d_y) + dest_x;
                            const Color8A * restrict srcp = (const Color8A *) (src->data + src->stride*o_y) + offs_x;
                            BB_dither_alpha_y8a_to_bb8_row(dstp, srcp, w, (o_y & 7U) << 3U, offs_x & 7U, dither_lut);
                        }
                    } else {
                        for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                            for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                                const Color8A * restrict srcptr;
                                BB_GET_PIXEL(src, sbb_rotation, Color8A, o_x, o_y, &srcptr);
                                const uint8_t alpha = srcptr->alpha;
                                if (alpha == 0) {
                                    // NOP
                                } else if (alpha == 0xFF) {
                                    Color8 * restrict dstptr;
                                    BB_GET_PIXEL(dst, dbb_rotation, Color8, d_x, d_y, &dstptr);
                                    dstptr->a = dither_o8x8(o_x, o_y, srcptr->a);
                                } else {
                                    const uint8_t ainv = alpha ^ 0xFF;
                                    Color8 * restrict dstptr;
                                    BB_GET_PIXEL(dst, dbb_rotation, Color8, d_x, d_y, &dstptr);
                                    dstptr->a = dither_o8x8(o_x, o_y, (uint8_t) DIV_255(dstptr->a * ainv + srcptr->a * alpha));
                                }
                            }
                        }
                    }
                    break;
                case TYPE_BBRGB16:
                    for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                        for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                            Color8 * restrict dstptr;
                            BB_GET_PIXEL(dst, dbb_rotation, Color8, d_x, d_y, &dstptr);
                            const ColorRGB16 * restrict srcptr;
                            BB_GET_PIXEL(src, sbb_rotation, ColorRGB16, o_x, o_y, &srcptr);
                            dstptr->a = dither_o8x8(o_x, o_y, (uint8_t) ColorRGB16_To_A(srcptr->v));
                        }
                    }
                    break;
                case TYPE_BBRGB24:
                    for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                        for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                            Color8 * restrict dstptr;
                            BB_GET_PIXEL(dst, dbb_rotation, Color8, d_x, d_y, &dstptr);
                            const ColorRGB24 * restrict srcptr;
                            BB_GET_PIXEL(src, sbb_rotation, ColorRGB24, o_x, o_y, &srcptr);
                            dstptr->a = dither_o8x8(o_x, o_y, (uint8_t) RGB_To_A(srcptr->r, srcptr->g, srcptr->b));
                        }
                    }
                    break;
                case TYPE_BBRGB32:
                    if (sbb_rotation == 0 && dbb_rotation == 0) {
                        dither_lut = dither_o8x8_get_lut();
                        for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                            Color8 * restrict dstp = (Color8 *) (dst->data + dst->stride*d_y) + dest_x;
                            const ColorRGB32 * restrict srcp = (const ColorRGB32 *) (src->data + src->stride*o_y) + offs_x;
                            BB_dither_alpha_rgb32_to_bb8_row(dstp, srcp, w, (o_y & 7U) << 3U, offs_x & 7U, dither_lut);
                        }
                    } else {
                        for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                            for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                                const ColorRGB32 * restrict srcptr;
                                BB_GET_PIXEL(src, sbb_rotation, ColorRGB32, o_x, o_y, &srcptr);
                                const uint8_t alpha = srcptr->alpha;
                                if (alpha == 0) {
                                    // NOP
                                } else if (alpha == 0xFF) {
                                    Color8 * restrict dstptr;
                                    BB_GET_PIXEL(dst, dbb_rotation, Color8, d_x, d_y, &dstptr);
                                    dstptr->a = dither_o8x8(o_x, o_y, (uint8_t) RGB_To_A(srcptr->r, srcptr->g, srcptr->b));
                                } else {
                                    const uint8_t ainv = alpha ^ 0xFF;
                                    const uint8_t srca = (uint8_t) RGB_To_A(srcptr->r, srcptr->g, srcptr->b);
                                    Color8 * restrict dstptr;
                                    BB_GET_PIXEL(dst, dbb_rotation, Color8, d_x, d_y, &dstptr);
                                    dstptr->a = dither_o8x8(o_x, o_y, (uint8_t) DIV_255(dstptr->a * ainv + srca * alpha));
                                }
                            }
                        }
                    }
                    break;
                default:
                    fprintf(stderr, "%s: incompatible bb (dst: BB8, src: %s) in file %s, line %d!\n",
                            __FUNCTION__, get_bbtype_name(sbb_type), __FILE__, __LINE__);
                    exit(1);
                    break;
            }
            break;
        default:
            return BB_alpha_blit_from(dst, src, dest_x, dest_y, offs_x, offs_y, w, h);
    }
}

// NOTE: Keep in sync w/ BB_alpha_blit_from!
//       The only functional change being that, when actually alpha-blending, src * alpha becomes src * 0xFF
//       Duplicating 350 LOC for that feels awesome! But saves a deeply nested branch in a pixel loop, which would be bad.
void BB_pmulalpha_blit_from(BlitBuffer * restrict dst, const BlitBuffer * restrict src,
        unsigned int dest_x, unsigned int dest_y, unsigned int offs_x, unsigned int offs_y, unsigned int w, unsigned int h) {
    const int dbb_type = GET_BB_TYPE(dst);
    const int sbb_type = GET_BB_TYPE(src);
    const int sbb_rotation = GET_BB_ROTATION(src);
    const int dbb_rotation = GET_BB_ROTATION(dst);
    switch (dbb_type) {
        case TYPE_BB8:
            switch (sbb_type) {
                case TYPE_BB8:
                    if (sbb_rotation == 0 && dbb_rotation == 0) {
                        for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                            Color8 * restrict dstp = (Color8 *) (dst->data + dst->stride*d_y) + dest_x;
                            const Color8 * restrict srcp = (const Color8 *) (src->data + src->stride*o_y) + offs_x;
                            for (unsigned int x = 0; x < w; x++) {
                                dstp[x] = srcp[x];
                            }
                        }
                    } else {
                        for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                            for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                                Color8 * restrict dstptr;
                                BB_GET_PIXEL(dst, dbb_rotation, Color8, d_x, d_y, &dstptr);
                                const Color8 * restrict srcptr;
                                BB_GET_PIXEL(src, sbb_rotation, Color8, o_x, o_y, &srcptr);
                                *dstptr = *srcptr;
                            }
                        }
                    }
                    break;
                case TYPE_BB8A:
                    if (sbb_rotation == 0 && dbb_rotation == 0) {
                        for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                            Color8 * restrict dstp = (Color8 *) (dst->data + dst->stride*d_y) + dest_x;
                            const Color8A * restrict srcp = (const Color8A *) (src->data + src->stride*o_y) + offs_x;
                            BB_bb8a_pmulalpha_to_bb8_row(dstp, srcp, w);
                        }
                    } else {
                        for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                            for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                                const Color8A * restrict srcptr;
                                BB_GET_PIXEL(src, sbb_rotation, Color8A, o_x, o_y, &srcptr);
                                const uint8_t alpha = srcptr->alpha;
                                if (alpha == 0) {
                                    // NOP
                                } else if (alpha == 0xFF) {
                                    Color8 * restrict dstptr;
                                    BB_GET_PIXEL(dst, dbb_rotation, Color8, d_x, d_y, &dstptr);
                                    dstptr->a = srcptr->a;
                                } else {
                                    const uint8_t ainv = alpha ^ 0xFF;
                                    Color8 * restrict dstptr;
                                    BB_GET_PIXEL(dst, dbb_rotation, Color8, d_x, d_y, &dstptr);
                                    dstptr->a = (uint8_t) DIV_255(dstptr->a * ainv + srcptr->a * 0xFF);
                                }
                            }
                        }
                    }
                    break;
                case TYPE_BBRGB16:
                    for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                        for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                            Color8 * restrict dstptr;
                            BB_GET_PIXEL(dst, dbb_rotation, Color8, d_x, d_y, &dstptr);
                            const ColorRGB16 * restrict srcptr;
                            BB_GET_PIXEL(src, sbb_rotation, ColorRGB16, o_x, o_y, &srcptr);
                            dstptr->a = (uint8_t) ColorRGB16_To_A(srcptr->v);
                        }
                    }
                    break;
                case TYPE_BBRGB24:
                    for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                        for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                            Color8 * restrict dstptr;
                            BB_GET_PIXEL(dst, dbb_rotation, Color8, d_x, d_y, &dstptr);
                            const ColorRGB24 * restrict srcptr;
                            BB_GET_PIXEL(src, sbb_rotation, ColorRGB24, o_x, o_y, &srcptr);
                            dstptr->a = (uint8_t) RGB_To_A(srcptr->r, srcptr->g, srcptr->b);
                        }
                    }
                    break;
                case TYPE_BBRGB32:
                    if (sbb_rotation == 0 && dbb_rotation == 0) {
                        for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                            Color8 * restrict dstp = (Color8 *) (dst->data + dst->stride*d_y) + dest_x;
                            const ColorRGB32 * restrict srcp = (const ColorRGB32 *) (src->data + src->stride*o_y) + offs_x;
                            BB_rgb32_pmulalpha_to_bb8_row(dstp, srcp, w);
                        }
                    } else {
                        for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                            for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                                const ColorRGB32 * restrict srcptr;
                                BB_GET_PIXEL(src, sbb_rotation, ColorRGB32, o_x, o_y, &srcptr);
                                const uint8_t alpha = srcptr->alpha;
                                if (alpha == 0) {
                                    // NOP
                                } else if (alpha == 0xFF) {
                                    Color8 * restrict dstptr;
                                    BB_GET_PIXEL(dst, dbb_rotation, Color8, d_x, d_y, &dstptr);
                                    dstptr->a = (uint8_t) RGB_To_A(srcptr->r, srcptr->g, srcptr->b);
                                } else {
                                    const uint8_t ainv = alpha ^ 0xFF;
                                    const uint8_t srca = (uint8_t) RGB_To_A(srcptr->r, srcptr->g, srcptr->b);
                                    Color8 * restrict dstptr;
                                    BB_GET_PIXEL(dst, dbb_rotation, Color8, d_x, d_y, &dstptr);
                                    dstptr->a = (uint8_t) DIV_255(dstptr->a * ainv + srca * 0xFF);
                                }
                            }
                        }
                    }
                    break;
                default:
                    fprintf(stderr, "%s: incompatible bb (dst: BB8, src: %s) in file %s, line %d!\n",
                            __FUNCTION__, get_bbtype_name(sbb_type), __FILE__, __LINE__);
                    exit(1);
                    break;
            }
            break;
        case TYPE_BB8A:
            switch (sbb_type) {
                case TYPE_BB8A:
                    for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                        for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                            const Color8A * restrict srcptr;
                            BB_GET_PIXEL(src, sbb_rotation, Color8A, o_x, o_y, &srcptr);
                            const uint8_t alpha = srcptr->alpha;
                            if (alpha == 0) {
                                // NOP
                            } else if (alpha == 0xFF) {
                                Color8A * restrict dstptr;
                                BB_GET_PIXEL(dst, dbb_rotation, Color8A, d_x, d_y, &dstptr);
                                *dstptr = *srcptr;
                            } else {
                                const uint8_t ainv = alpha ^ 0xFF;
                                Color8A * restrict dstptr;
                                BB_GET_PIXEL(dst, dbb_rotation, Color8A, d_x, d_y, &dstptr);
                                dstptr->a = (uint8_t) DIV_255(dstptr->a * ainv + srcptr->a * 0xFF);
                            }
                        }
                    }
                    break;
                default:
                    fprintf(stderr, "%s: incompatible bb (dst: BB8A, src: %s) in file %s, line %d!\n",
                            __FUNCTION__, get_bbtype_name(sbb_type), __FILE__, __LINE__);
                    exit(1);
                    break;
            }
            break;
        case TYPE_BBRGB16:
            switch (sbb_type) {
                case TYPE_BB8:
                    for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                        for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                            ColorRGB16 * restrict dstptr;
                            BB_GET_PIXEL(dst, dbb_rotation, ColorRGB16, d_x, d_y, &dstptr);
                            const Color8 * restrict srcptr;
                            BB_GET_PIXEL(src, sbb_rotation, Color8, o_x, o_y, &srcptr);
                            dstptr->v = (uint16_t) RGB_To_RGB16(srcptr->a, srcptr->a, srcptr->a);
                        }
                    }
                    break;
                case TYPE_BB8A:
                    for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                        for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                            const Color8A * restrict srcptr;
                            BB_GET_PIXEL(src, sbb_rotation, Color8A, o_x, o_y, &srcptr);
                            const uint8_t alpha = srcptr->alpha;
                            if (alpha == 0) {
                                // NOP
                            } else if (alpha == 0xFF) {
                                ColorRGB16 * restrict dstptr;
                                BB_GET_PIXEL(dst, dbb_rotation, ColorRGB16, d_x, d_y, &dstptr);
                                dstptr->v = (uint16_t) RGB_To_RGB16(srcptr->a, srcptr->a, srcptr->a);
                            } else {
                                const uint8_t ainv = alpha ^ 0xFF;
                                ColorRGB16 * restrict dstptr;
                                BB_GET_PIXEL(dst, dbb_rotation, ColorRGB16, d_x, d_y, &dstptr);
                                const uint8_t dsta = (uint8_t) ColorRGB16_To_A(dstptr->v);
                                const uint8_t bdsta = (uint8_t) DIV_255(dsta * ainv + srcptr->a * 0xFF);
                                dstptr->v = (uint16_t) RGB_To_RGB16(bdsta, bdsta, bdsta);
                            }
                        }
                    }
                    break;
                case TYPE_BBRGB16:
                    for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                        for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                            ColorRGB16 * restrict dstptr;
                            BB_GET_PIXEL(dst, dbb_rotation, ColorRGB16, d_x, d_y, &dstptr);
                            const ColorRGB16 * restrict srcptr;
                            BB_GET_PIXEL(src, sbb_rotation, ColorRGB16, o_x, o_y, &srcptr);
                            *dstptr = *srcptr;
                        }
                    }
                    break;
                case TYPE_BBRGB24:
                    for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                        for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                            ColorRGB16 * restrict dstptr;
                            BB_GET_PIXEL(dst, dbb_rotation, ColorRGB16, d_x, d_y, &dstptr);
                            const ColorRGB24 * restrict srcptr;
                            BB_GET_PIXEL(src, sbb_rotation, ColorRGB24, o_x, o_y, &srcptr);
                            dstptr->v = (uint16_t) RGB_To_RGB16(srcptr->r, srcptr->g, srcptr->b);
                        }
                    }
                    break;
                case TYPE_BBRGB32:
                    for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                        for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                            const ColorRGB32 * restrict srcptr;
                            BB_GET_PIXEL(src, sbb_rotation, ColorRGB32, o_x, o_y, &srcptr);
                            const uint8_t alpha = srcptr->alpha;
                            if (alpha == 0) {
                                // NOP
                            } else if (alpha == 0xFF) {
                                ColorRGB16 * restrict dstptr;
                                BB_GET_PIXEL(dst, dbb_rotation, ColorRGB16, d_x, d_y, &dstptr);
                                dstptr->v = (uint16_t) RGB_To_RGB16(srcptr->r, srcptr->g, srcptr->b);
                            } else {
                                const uint8_t ainv = alpha ^ 0xFF;
                                ColorRGB16 * restrict dstptr;
                                BB_GET_PIXEL(dst, dbb_rotation, ColorRGB16, d_x, d_y, &dstptr);
                                const uint8_t r = (uint8_t) DIV_255(ColorRGB16_GetR(dstptr->v) * ainv + srcptr->r * 0xFF);
                                const uint8_t g = (uint8_t) DIV_255(ColorRGB16_GetG(dstptr->v) * ainv + srcptr->g * 0xFF);
                                const uint8_t b = (uint8_t) DIV_255(ColorRGB16_GetB(dstptr->v) * ainv + srcptr->b * 0xFF);
                                dstptr->v = (uint16_t) RGB_To_RGB16(r, g, b);
                            }
                        }
                    }
                    break;
                default:
                    fprintf(stderr, "%s: incompatible bb (dst: BBRGB16, src: %s) in file %s, line %d!\n",
                            __FUNCTION__, get_bbtype_name(sbb_type), __FILE__, __LINE__);
                    exit(1);
                    break;
            }
            break;
        case TYPE_BBRGB24:
            switch (sbb_type) {
                case TYPE_BBRGB24:
                    for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                        for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                            ColorRGB24 * restrict dstptr;
                            BB_GET_PIXEL(dst, dbb_rotation, ColorRGB24, d_x, d_y, &dstptr);
                            const ColorRGB24 * restrict srcptr;
                            BB_GET_PIXEL(src, sbb_rotation, ColorRGB24, o_x, o_y, &srcptr);
                            *dstptr = *srcptr;
                        }
                    }
                    break;
                default:
                    fprintf(stderr, "%s: incompatible bb (dst: BBRGB24, src: %s) in file %s, line %d!\n",
                            __FUNCTION__, get_bbtype_name(sbb_type), __FILE__, __LINE__);
                    exit(1);
                    break;
            }
            break;
        case TYPE_BBRGB32:
            switch (sbb_type) {
                case TYPE_BB8:
                    for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                        for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                            ColorRGB32 * restrict dstptr;
                            BB_GET_PIXEL(dst, dbb_rotation, ColorRGB32, d_x, d_y, &dstptr);
                            const Color8 * restrict srcptr;
                            BB_GET_PIXEL(src, sbb_rotation, Color8, o_x, o_y, &srcptr);
                            dstptr->r = srcptr->a;
                            dstptr->g = srcptr->a;
                            dstptr->b = srcptr->a;
                            //dstptr->alpha = dstptr->alpha;
                        }
                    }
                    break;
                case TYPE_BB8A:
                    for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                        for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                            const Color8A * restrict srcptr;
                            BB_GET_PIXEL(src, sbb_rotation, Color8A, o_x, o_y, &srcptr);
                            const uint8_t alpha = srcptr->alpha;
                            if (alpha == 0) {
                                // NOP
                            } else if (alpha == 0xFF) {
                                ColorRGB32 * restrict dstptr;
                                BB_GET_PIXEL(dst, dbb_rotation, ColorRGB32, d_x, d_y, &dstptr);
                                dstptr->r = srcptr->a;
                                dstptr->g = srcptr->a;
                                dstptr->b = srcptr->a;
                                //dstptr->alpha = srcptr->alpha;
                            } else {
                                const uint8_t ainv = alpha ^ 0xFF;
                                ColorRGB32 * restrict dstptr;
                                BB_GET_PIXEL(dst, dbb_rotation, ColorRGB32, d_x, d_y, &dstptr);
                                const uint8_t dsta = (uint8_t) RGB_To_A(dstptr->r, dstptr->g, dstptr->b);
                                const uint8_t bdsta = (uint8_t) DIV_255(dsta * ainv + srcptr->a * 0xFF);
                                dstptr->r = bdsta;
                                dstptr->g = bdsta;
                                dstptr->b = bdsta;
                                //dstptr->alpha = dstptr->alpha;
                            }
                        }
                    }
                    break;
                case TYPE_BBRGB16:
                    for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                        for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                            ColorRGB32 * restrict dstptr;
                            BB_GET_PIXEL(dst, dbb_rotation, ColorRGB32, d_x, d_y, &dstptr);
                            const ColorRGB16 * restrict srcptr;
                            BB_GET_PIXEL(src, sbb_rotation, ColorRGB16, o_x, o_y, &srcptr);
                            dstptr->r = (uint8_t) ColorRGB16_GetR(srcptr->v);
                            dstptr->g = (uint8_t) ColorRGB16_GetG(srcptr->v);
                            dstptr->b = (uint8_t) ColorRGB16_GetB(srcptr->v);
                            //dstptr->alpha = dstptr->alpha;
                        }
                    }
                    break;
                case TYPE_BBRGB24:
                    for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                        for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                            ColorRGB32 * restrict dstptr;
                            BB_GET_PIXEL(dst, dbb_rotation, ColorRGB32, d_x, d_y, &dstptr);
                            const ColorRGB24 * restrict srcptr;
                            BB_GET_PIXEL(src, sbb_rotation, ColorRGB24, o_x, o_y, &srcptr);
                            dstptr->r = srcptr->r;
                            dstptr->g = srcptr->g;
                            dstptr->b = srcptr->b;
                            //dstptr->alpha = dstptr->alpha;
                        }
                    }
                    break;
                case TYPE_BBRGB32:
                    for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                        for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                            const ColorRGB32 * restrict srcptr;
                            BB_GET_PIXEL(src, sbb_rotation, ColorRGB32, o_x, o_y, &srcptr);
                            const uint8_t alpha = srcptr->alpha;
                            if (alpha == 0) {
                                // NOP
                            } else if (alpha == 0xFF) {
                                ColorRGB32 * restrict dstptr;
                                BB_GET_PIXEL(dst, dbb_rotation, ColorRGB32, d_x, d_y, &dstptr);
                                *dstptr = *srcptr;
                            } else {
                                const uint8_t ainv = alpha ^ 0xFF;
                                ColorRGB32 * restrict dstptr;
                                BB_GET_PIXEL(dst, dbb_rotation, ColorRGB32, d_x, d_y, &dstptr);
                                dstptr->r = (uint8_t) DIV_255(dstptr->r * ainv + srcptr->r * 0xFF);
                                dstptr->g = (uint8_t) DIV_255(dstptr->g * ainv + srcptr->g * 0xFF);
                                dstptr->b = (uint8_t) DIV_255(dstptr->b * ainv + srcptr->b * 0xFF);
                                //dstptr->alpha = dstptr->alpha;
                            }
                        }
                    }
                    break;
                default:
                    fprintf(stderr, "%s: incompatible bb (dst: BBRGB32, src: %s) in file %s, line %d!\n",
                            __FUNCTION__, get_bbtype_name(sbb_type), __FILE__, __LINE__);
                    exit(1);
                    break;
            }
            break;
        default:
            fprintf(stderr, "%s: incompatible bb (dst: %s, src: %s) in file %s, line %d!\n",
                    __FUNCTION__, get_bbtype_name(dbb_type), get_bbtype_name(sbb_type), __FILE__, __LINE__);
            exit(1);
            break;
    }
}

// NOTE: Keep in sync w/ BB_pmulalpha_blit_from!
//       Dithering is only honored for BB8 dbb ;).
void BB_dither_pmulalpha_blit_from(BlitBuffer * restrict dst, const BlitBuffer * restrict src,
        unsigned int dest_x, unsigned int dest_y, unsigned int offs_x, unsigned int offs_y, unsigned int w, unsigned int h) {
    const int dbb_type = GET_BB_TYPE(dst);
    const int sbb_type = GET_BB_TYPE(src);
    const int sbb_rotation = GET_BB_ROTATION(src);
    const int dbb_rotation = GET_BB_ROTATION(dst);
    const uint8_t (* restrict dither_lut)[256] = NULL;
    switch (dbb_type) {
        case TYPE_BB8:
            switch (sbb_type) {
                case TYPE_BB8:
                    if (sbb_rotation == 0 && dbb_rotation == 0) {
                        dither_lut = dither_o8x8_get_lut();
                        for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                            Color8 * restrict dstp = (Color8 *) (dst->data + dst->stride*d_y) + dest_x;
                            const Color8 * restrict srcp = (const Color8 *) (src->data + src->stride*o_y) + offs_x;
                            BB_dither_y8_to_bb8_row(dstp, srcp, w, (o_y & 7U) << 3U, offs_x & 7U, dither_lut);
                        }
                    } else {
                        for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                            for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                                Color8 * restrict dstptr;
                                BB_GET_PIXEL(dst, dbb_rotation, Color8, d_x, d_y, &dstptr);
                                const Color8 * restrict srcptr;
                                BB_GET_PIXEL(src, sbb_rotation, Color8, o_x, o_y, &srcptr);
                                dstptr->a = dither_o8x8(o_x, o_y, srcptr->a);
                            }
                        }
                    }
                    break;
                case TYPE_BB8A:
                    if (sbb_rotation == 0 && dbb_rotation == 0) {
                        dither_lut = dither_o8x8_get_lut();
                        for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                            Color8 * restrict dstp = (Color8 *) (dst->data + dst->stride*d_y) + dest_x;
                            const Color8A * restrict srcp = (const Color8A *) (src->data + src->stride*o_y) + offs_x;
                            BB_dither_pmulalpha_y8a_to_bb8_row(dstp, srcp, w, (o_y & 7U) << 3U, offs_x & 7U, dither_lut);
                        }
                    } else {
                        for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                            for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                                const Color8A * restrict srcptr;
                                BB_GET_PIXEL(src, sbb_rotation, Color8A, o_x, o_y, &srcptr);
                                const uint8_t alpha = srcptr->alpha;
                                if (alpha == 0) {
                                    // NOP
                                } else if (alpha == 0xFF) {
                                    Color8 * restrict dstptr;
                                    BB_GET_PIXEL(dst, dbb_rotation, Color8, d_x, d_y, &dstptr);
                                    dstptr->a = dither_o8x8(o_x, o_y, srcptr->a);
                                } else {
                                    const uint8_t ainv = alpha ^ 0xFF;
                                    Color8 * restrict dstptr;
                                    BB_GET_PIXEL(dst, dbb_rotation, Color8, d_x, d_y, &dstptr);
                                    dstptr->a = dither_o8x8(o_x, o_y, (uint8_t) DIV_255(dstptr->a * ainv + srcptr->a * 0xFF));
                                }
                            }
                        }
                    }
                    break;
                case TYPE_BBRGB16:
                    for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                        for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                            Color8 * restrict dstptr;
                            BB_GET_PIXEL(dst, dbb_rotation, Color8, d_x, d_y, &dstptr);
                            const ColorRGB16 * restrict srcptr;
                            BB_GET_PIXEL(src, sbb_rotation, ColorRGB16, o_x, o_y, &srcptr);
                            dstptr->a = dither_o8x8(o_x, o_y, (uint8_t) ColorRGB16_To_A(srcptr->v));
                        }
                    }
                    break;
                case TYPE_BBRGB24:
                    for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                        for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                            Color8 * restrict dstptr;
                            BB_GET_PIXEL(dst, dbb_rotation, Color8, d_x, d_y, &dstptr);
                            const ColorRGB24 * restrict srcptr;
                            BB_GET_PIXEL(src, sbb_rotation, ColorRGB24, o_x, o_y, &srcptr);
                            dstptr->a = dither_o8x8(o_x, o_y, (uint8_t) RGB_To_A(srcptr->r, srcptr->g, srcptr->b));
                        }
                    }
                    break;
                case TYPE_BBRGB32:
                    if (sbb_rotation == 0 && dbb_rotation == 0) {
                        dither_lut = dither_o8x8_get_lut();
                        for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                            Color8 * restrict dstp = (Color8 *) (dst->data + dst->stride*d_y) + dest_x;
                            const ColorRGB32 * restrict srcp = (const ColorRGB32 *) (src->data + src->stride*o_y) + offs_x;
                            BB_dither_pmulalpha_rgb32_to_bb8_row(dstp, srcp, w, (o_y & 7U) << 3U, offs_x & 7U, dither_lut);
                        }
                    } else {
                        for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                            for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                                const ColorRGB32 * restrict srcptr;
                                BB_GET_PIXEL(src, sbb_rotation, ColorRGB32, o_x, o_y, &srcptr);
                                const uint8_t alpha = srcptr->alpha;
                                if (alpha == 0) {
                                    // NOP
                                } else if (alpha == 0xFF) {
                                    Color8 * restrict dstptr;
                                    BB_GET_PIXEL(dst, dbb_rotation, Color8, d_x, d_y, &dstptr);
                                    dstptr->a = dither_o8x8(o_x, o_y, (uint8_t) RGB_To_A(srcptr->r, srcptr->g, srcptr->b));
                                } else {
                                    const uint8_t ainv = alpha ^ 0xFF;
                                    const uint8_t srca = (uint8_t) RGB_To_A(srcptr->r, srcptr->g, srcptr->b);
                                    Color8 * restrict dstptr;
                                    BB_GET_PIXEL(dst, dbb_rotation, Color8, d_x, d_y, &dstptr);
                                    dstptr->a = dither_o8x8(o_x, o_y, (uint8_t) DIV_255(dstptr->a * ainv + srca * 0xFF));
                                }
                            }
                        }
                    }
                    break;
                default:
                    fprintf(stderr, "%s: incompatible bb (dst: BB8, src: %s) in file %s, line %d!\n",
                            __FUNCTION__, get_bbtype_name(sbb_type), __FILE__, __LINE__);
                    exit(1);
                    break;
            }
            break;
        default:
            return BB_pmulalpha_blit_from(dst, src, dest_x, dest_y, offs_x, offs_y, w, h);
    }
}

void BB_invert_blit_from(BlitBuffer * restrict dst, const BlitBuffer * restrict src,
        unsigned int dest_x, unsigned int dest_y, unsigned int offs_x, unsigned int offs_y, unsigned int w, unsigned int h) {
    const int dbb_type = GET_BB_TYPE(dst);
    const int sbb_type = GET_BB_TYPE(src);
    const int sbb_rotation = GET_BB_ROTATION(src);
    const int dbb_rotation = GET_BB_ROTATION(dst);
    if (dbb_type != sbb_type) {
        fprintf(stderr, "%s: incompatible bb (dst: %s, src: %s) in file %s, line %d!\n",
                __FUNCTION__, get_bbtype_name(dbb_type), get_bbtype_name(sbb_type), __FILE__, __LINE__);
        exit(1);
    }
    switch (dbb_type) {
        case TYPE_BB8:
            for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                    Color8 * restrict dstptr;
                    BB_GET_PIXEL(dst, dbb_rotation, Color8, d_x, d_y, &dstptr);
                    const Color8 * restrict srcptr;
                    BB_GET_PIXEL(src, sbb_rotation, Color8, o_x, o_y, &srcptr);
                    dstptr->a = srcptr->a ^ 0xFF;
                }
            }
            break;
        case TYPE_BB8A:
            for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                    Color8A * restrict dstptr;
                    BB_GET_PIXEL(dst, dbb_rotation, Color8A, d_x, d_y, &dstptr);
                    const Color8A *srcptr;
                    BB_GET_PIXEL(src, sbb_rotation, Color8A, o_x, o_y, &srcptr);
                    dstptr->a = srcptr->a ^ 0xFF;
                }
            }
            break;
        case TYPE_BBRGB16:
            // NOTE: Much like BB_invert_rect, innacurate
            for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                    ColorRGB16 * restrict dstptr;
                    BB_GET_PIXEL(dst, dbb_rotation, ColorRGB16, d_x, d_y, &dstptr);
                    const ColorRGB16 * restrict srcptr;
                    BB_GET_PIXEL(src, sbb_rotation, ColorRGB16, o_x, o_y, &srcptr);
                    dstptr->v = srcptr->v ^ 0xFFFF;
                }
            }
            break;
        case TYPE_BBRGB24:
            for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                    ColorRGB24 * restrict dstptr;
                    BB_GET_PIXEL(dst, dbb_rotation, ColorRGB24, d_x, d_y, &dstptr);
                    const ColorRGB24 * restrict srcptr;
                    BB_GET_PIXEL(src, sbb_rotation, ColorRGB24, o_x, o_y, &srcptr);
                    dstptr->r = srcptr->r ^ 0xFF;
                    dstptr->g = srcptr->g ^ 0xFF;
                    dstptr->b = srcptr->b ^ 0xFF;
                }
            }
            break;
        case TYPE_BBRGB32:
            for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                    ColorRGB32 * restrict dstptr;
                    BB_GET_PIXEL(dst, dbb_rotation, ColorRGB32, d_x, d_y, &dstptr);
                    const ColorRGB32 * restrict srcptr;
                    BB_GET_PIXEL(src, sbb_rotation, ColorRGB32, o_x, o_y, &srcptr);
                    *(uint32_t*) dstptr = *(uint32_t*) srcptr ^ 0x00FFFFFF;
                }
            }
            break;
    }
}

void BB_color_blit_from(BlitBuffer * restrict dst, const BlitBuffer * restrict src,
        unsigned int dest_x, unsigned int dest_y, unsigned int offs_x, unsigned int offs_y, unsigned int w, unsigned int h, const Color8A * restrict color) {
    const int dbb_type = GET_BB_TYPE(dst);
    const int sbb_type = GET_BB_TYPE(src);
    const int sbb_rotation = GET_BB_ROTATION(src);
    const int dbb_rotation = GET_BB_ROTATION(dst);
    switch (dbb_type) {
        case TYPE_BB8:
            for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                    uint8_t alpha;
                    SET_ALPHA_FROM_A(src, sbb_type, sbb_rotation, o_x, o_y, &alpha);
                    if (alpha == 0) {
                        // NOP
                    } else if (alpha == 0xFF) {
                        Color8 * restrict dstptr;
                        BB_GET_PIXEL(dst, dbb_rotation, Color8, d_x, d_y, &dstptr);
                        dstptr->a = color->a;
                    } else {
                        const uint8_t ainv = alpha ^ 0xFF;
                        Color8 * restrict dstptr;
                        BB_GET_PIXEL(dst, dbb_rotation, Color8, d_x, d_y, &dstptr);
                        dstptr->a = (uint8_t) DIV_255(dstptr->a * ainv + color->a * alpha);
                    }
                }
            }
            break;
        case TYPE_BB8A:
            for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                    uint8_t alpha;
                    SET_ALPHA_FROM_A(src, sbb_type, sbb_rotation, o_x, o_y, &alpha);
                    if (alpha == 0) {
                        // NOP
                    } else if (alpha == 0xFF) {
                        Color8A * restrict dstptr;
                        BB_GET_PIXEL(dst, dbb_rotation, Color8A, d_x, d_y, &dstptr);
                        dstptr->a = color->a;
                    } else {
                        const uint8_t ainv = alpha ^ 0xFF;
                        Color8A * restrict dstptr;
                        BB_GET_PIXEL(dst, dbb_rotation, Color8A, d_x, d_y, &dstptr);
                        dstptr->a = (uint8_t) DIV_255(dstptr->a * ainv + color->a * alpha);
                    }
                }
            }
            break;
        case TYPE_BBRGB16:
            for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                    uint8_t alpha;
                    SET_ALPHA_FROM_A(src, sbb_type, sbb_rotation, o_x, o_y, &alpha);
                    if (alpha == 0) {
                        // NOP
                    } else if (alpha == 0xFF) {
                        ColorRGB16 * restrict dstptr;
                        BB_GET_PIXEL(dst, dbb_rotation, ColorRGB16, d_x, d_y, &dstptr);
                        dstptr->v = (uint16_t) RGB_To_RGB16(color->a, color->a, color->a);
                    } else {
                        const uint8_t ainv = alpha ^ 0xFF;
                        ColorRGB16 * restrict dstptr;
                        BB_GET_PIXEL(dst, dbb_rotation, ColorRGB16, d_x, d_y, &dstptr);
                        const uint8_t r = (uint8_t) DIV_255(ColorRGB16_GetR(dstptr->v) * ainv + color->a * alpha);
                        const uint8_t g = (uint8_t) DIV_255(ColorRGB16_GetG(dstptr->v) * ainv + color->a * alpha);
                        const uint8_t b = (uint8_t) DIV_255(ColorRGB16_GetB(dstptr->v) * ainv + color->a * alpha);
                        dstptr->v = (uint16_t) RGB_To_RGB16(r, g, b);
                    }
                }
            }
            break;
        case TYPE_BBRGB24:
            for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                    uint8_t alpha;
                    SET_ALPHA_FROM_A(src, sbb_type, sbb_rotation, o_x, o_y, &alpha);
                    if (alpha == 0) {
                        // NOP
                    } else if (alpha == 0xFF) {
                        ColorRGB24 * restrict dstptr;
                        BB_GET_PIXEL(dst, dbb_rotation, ColorRGB24, d_x, d_y, &dstptr);
                        dstptr->r = color->a;
                        dstptr->g = color->a;
                        dstptr->b = color->a;
                    } else {
                        const uint8_t ainv = alpha ^ 0xFF;
                        ColorRGB24 * restrict dstptr;
                        BB_GET_PIXEL(dst, dbb_rotation, ColorRGB24, d_x, d_y, &dstptr);
                        dstptr->r = (uint8_t) DIV_255(dstptr->r * ainv + color->a * alpha);
                        dstptr->g = (uint8_t) DIV_255(dstptr->g * ainv + color->a * alpha);
                        dstptr->b = (uint8_t) DIV_255(dstptr->b * ainv + color->a * alpha);
                    }
                }
            }
            break;
        case TYPE_BBRGB32:
            for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                    // NOTE: GCC *may* throw a -Wmaybe-uninitialized about alpha here,
                    //       because of the lack of default case in the SET_ALPHA_FROM_A switch.
                    //       Not a cause for alarm here :).
                    uint8_t alpha;
                    SET_ALPHA_FROM_A(src, sbb_type, sbb_rotation, o_x, o_y, &alpha);
                    if (alpha == 0) {
                        // NOP
                    } else if (alpha == 0xFF) {
                        ColorRGB32 * restrict dstptr;
                        BB_GET_PIXEL(dst, dbb_rotation, ColorRGB32, d_x, d_y, &dstptr);
                        dstptr->r = color->a;
                        dstptr->g = color->a;
                        dstptr->b = color->a;
                    } else {
                        const uint8_t ainv = alpha ^ 0xFF;
                        ColorRGB32 * restrict dstptr;
                        BB_GET_PIXEL(dst, dbb_rotation, ColorRGB32, d_x, d_y, &dstptr);
                        dstptr->r = (uint8_t) DIV_255(dstptr->r * ainv + color->a * alpha);
                        dstptr->g = (uint8_t) DIV_255(dstptr->g * ainv + color->a * alpha);
                        dstptr->b = (uint8_t) DIV_255(dstptr->b * ainv + color->a * alpha);
                    }
                }
            }
            break;
    }
}

void BB_color_blit_from_RGB32(BlitBuffer * restrict dst, const BlitBuffer * restrict src,
        unsigned int dest_x, unsigned int dest_y, unsigned int offs_x, unsigned int offs_y, unsigned int w, unsigned int h, const ColorRGB32 * restrict color) {
    const int dbb_type = GET_BB_TYPE(dst);
    const int sbb_type = GET_BB_TYPE(src);
    const int sbb_rotation = GET_BB_ROTATION(src);
    const int dbb_rotation = GET_BB_ROTATION(dst);
    switch (dbb_type) {
        case TYPE_BB8:
            {
                const uint8_t source_y8 = RGB_To_A(color->r, color->g, color->b);
                for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                    for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                        uint8_t alpha;
                        SET_ALPHA_FROM_A(src, sbb_type, sbb_rotation, o_x, o_y, &alpha);
                        if (alpha == 0) {
                            // NOP
                        } else if (alpha == 0xFF) {
                            Color8 * restrict dstptr;
                            BB_GET_PIXEL(dst, dbb_rotation, Color8, d_x, d_y, &dstptr);
                            dstptr->a = source_y8;
                        } else {
                            const uint8_t ainv = alpha ^ 0xFF;
                            Color8 * restrict dstptr;
                            BB_GET_PIXEL(dst, dbb_rotation, Color8, d_x, d_y, &dstptr);
                            dstptr->a = (uint8_t) DIV_255(dstptr->a * ainv + source_y8 * alpha);
                        }
                    }
                }
            }
            break;
        case TYPE_BB8A:
            {
                const uint8_t source_y8 = RGB_To_A(color->r, color->g, color->b);
                for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                    for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                        uint8_t alpha;
                        SET_ALPHA_FROM_A(src, sbb_type, sbb_rotation, o_x, o_y, &alpha);
                        if (alpha == 0) {
                            // NOP
                        } else if (alpha == 0xFF) {
                            Color8A * restrict dstptr;
                            BB_GET_PIXEL(dst, dbb_rotation, Color8A, d_x, d_y, &dstptr);
                            dstptr->a = source_y8;
                        } else {
                            const uint8_t ainv = alpha ^ 0xFF;
                            Color8A * restrict dstptr;
                            BB_GET_PIXEL(dst, dbb_rotation, Color8A, d_x, d_y, &dstptr);
                            dstptr->a = (uint8_t) DIV_255(dstptr->a * ainv + source_y8 * alpha);
                        }
                    }
                }
            }
            break;
        case TYPE_BBRGB16:
            for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                    uint8_t alpha;
                    SET_ALPHA_FROM_A(src, sbb_type, sbb_rotation, o_x, o_y, &alpha);
                    if (alpha == 0) {
                        // NOP
                    } else if (alpha == 0xFF) {
                        ColorRGB16 * restrict dstptr;
                        BB_GET_PIXEL(dst, dbb_rotation, ColorRGB16, d_x, d_y, &dstptr);
                        dstptr->v = (uint16_t) RGB_To_RGB16(color->r, color->g, color->b);
                    } else {
                        const uint8_t ainv = alpha ^ 0xFF;
                        ColorRGB16 * restrict dstptr;
                        BB_GET_PIXEL(dst, dbb_rotation, ColorRGB16, d_x, d_y, &dstptr);
                        const uint8_t r = (uint8_t) DIV_255(ColorRGB16_GetR(dstptr->v) * ainv + color->r * alpha);
                        const uint8_t g = (uint8_t) DIV_255(ColorRGB16_GetG(dstptr->v) * ainv + color->g * alpha);
                        const uint8_t b = (uint8_t) DIV_255(ColorRGB16_GetB(dstptr->v) * ainv + color->b * alpha);
                        dstptr->v = (uint16_t) RGB_To_RGB16(r, g, b);
                    }
                }
            }
            break;
        case TYPE_BBRGB24:
            for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                    uint8_t alpha;
                    SET_ALPHA_FROM_A(src, sbb_type, sbb_rotation, o_x, o_y, &alpha);
                    if (alpha == 0) {
                        // NOP
                    } else if (alpha == 0xFF) {
                        ColorRGB24 * restrict dstptr;
                        BB_GET_PIXEL(dst, dbb_rotation, ColorRGB24, d_x, d_y, &dstptr);
                        dstptr->r = color->r;
                        dstptr->g = color->g;
                        dstptr->b = color->b;
                    } else {
                        const uint8_t ainv = alpha ^ 0xFF;
                        ColorRGB24 * restrict dstptr;
                        BB_GET_PIXEL(dst, dbb_rotation, ColorRGB24, d_x, d_y, &dstptr);
                        dstptr->r = (uint8_t) DIV_255(dstptr->r * ainv + color->r * alpha);
                        dstptr->g = (uint8_t) DIV_255(dstptr->g * ainv + color->g * alpha);
                        dstptr->b = (uint8_t) DIV_255(dstptr->b * ainv + color->b * alpha);
                    }
                }
            }
            break;
        case TYPE_BBRGB32:
            for (unsigned int d_y = dest_y, o_y = offs_y; d_y < dest_y + h; d_y++, o_y++) {
                for (unsigned int d_x = dest_x, o_x = offs_x; d_x < dest_x + w; d_x++, o_x++) {
                    // NOTE: GCC *may* throw a -Wmaybe-uninitialized about alpha here,
                    //       because of the lack of default case in the SET_ALPHA_FROM_A switch.
                    //       Not a cause for alarm here :).
                    uint8_t alpha;
                    SET_ALPHA_FROM_A(src, sbb_type, sbb_rotation, o_x, o_y, &alpha);
                    if (alpha == 0) {
                        // NOP
                    } else if (alpha == 0xFF) {
                        ColorRGB32 * restrict dstptr;
                        BB_GET_PIXEL(dst, dbb_rotation, ColorRGB32, d_x, d_y, &dstptr);
                        dstptr->r = color->r;
                        dstptr->g = color->g;
                        dstptr->b = color->b;
                    } else {
                        const uint8_t ainv = alpha ^ 0xFF;
                        ColorRGB32 * restrict dstptr;
                        BB_GET_PIXEL(dst, dbb_rotation, ColorRGB32, d_x, d_y, &dstptr);
                        dstptr->r = (uint8_t) DIV_255(dstptr->r * ainv + color->r * alpha);
                        dstptr->g = (uint8_t) DIV_255(dstptr->g * ainv + color->g * alpha);
                        dstptr->b = (uint8_t) DIV_255(dstptr->b * ainv + color->b * alpha);
                    }
                }
            }
            break;
    }
}

// Information about those three algorithms can be found on http://members.chello.at/~easyfilter/ (Zingl Alois)
void BB_paint_rounded_corner_noAA(BlitBuffer * restrict bb, unsigned int off_x, unsigned int off_y, unsigned int w, unsigned int h, int bw, int r, uint8_t c);
void BB_paint_rounded_corner_AA(BlitBuffer * restrict bb, unsigned int off_x, unsigned int off_y, unsigned int w, unsigned int h, int bw, int r, uint8_t c);
void BB_paint_rounded_corner_AA_1px(BlitBuffer * restrict bb, unsigned int off_x, unsigned int off_y, unsigned int w, unsigned int h, int r, uint8_t c);

void BB_paint_rounded_corner(BlitBuffer * restrict bb, unsigned int off_x, unsigned int off_y, unsigned int w, unsigned int h, unsigned int bw, unsigned int r, uint8_t c, int anti_aliasing) {
    /*
    if (2*r > h || 2*r > w || r == 0) {
        // NOP
        return;
    }
    */

    r = MIN(r, MIN(h, w));
    if (bw > r) {
        bw = r;
    }

    if (!anti_aliasing) {
        BB_paint_rounded_corner_noAA(bb, off_x, off_y, w, h, bw, r, c);
    } else {
        if (bw == 1) {
            BB_paint_rounded_corner_AA_1px(bb, off_x, off_y, w, h, r, c);
        } else {
            BB_paint_rounded_corner_AA(bb, off_x, off_y, w, h, bw, r, c);
        }
    }
}

void BB_paint_rounded_corner_noAA(BlitBuffer * restrict bb, unsigned int off_x, unsigned int off_y, unsigned int w, unsigned int h, int bw, int r, uint8_t c) {

    const int bb_type = GET_BB_TYPE(bb);
    const int bb_rotation = GET_BB_ROTATION(bb);
    const unsigned int bb_width = BB_GET_WIDTH(bb);
    const unsigned int bb_height = BB_GET_HEIGHT(bb);

    /* The used algorithm is described in
     * https://de.wikipedia.org/wiki/Bresenham-Algorithmus#Kreisvariante_des_Algorithmus
     */

    // r ... radius of outer circle
    int x = 0;
    int y = r;
    int f = 1 - r;
    int ddF_x = 0;
    int ddF_y = -2 * r;

    // r2 ... radius of inner circle; might be zero
    const unsigned int r2 = r - bw;

    int x2 = 0;
    int y2 = r2;

    int f2 = 1 - r2;
    int ddF2_x = 0;
    int ddF2_y = -2 * r2;

    while(x < y)
    {
        if (f >= 0) {
            --y;
            ddF_y += 2;
            f += ddF_y;
        }
        ++x;
        ddF_x += 2;
        f += ddF_x + 1;

        if (r2 != 0 ) {
            if (f2 >= 0)
            {
                --y2;
                ddF2_y += 2;
                f2 += ddF2_y;
            }
            ++x2;
            ddF2_x += 2;
            f2 += ddF2_x + 1;
        }

        // Fill between inner and outer circle.
        for (int tmp_y = y; tmp_y > y2; tmp_y--) {
            if (bb_type == TYPE_BB8) {
                const Color8 color = { .a = c };

                BB8_SET_PIXEL_CLAMPED(bb, bb_rotation, (w-r)+off_x+x-1, (h-r)+off_y+tmp_y-1, bb_width, bb_height, &color);
                BB8_SET_PIXEL_CLAMPED(bb, bb_rotation, (w-r)+off_x+tmp_y-1, (h-r)+off_y+x-1, bb_width, bb_height, &color);

                BB8_SET_PIXEL_CLAMPED(bb, bb_rotation, (w-r)+off_x+tmp_y-1, (r)+off_y-x, bb_width, bb_height, &color);
                BB8_SET_PIXEL_CLAMPED(bb, bb_rotation, (w-r)+off_x+x-1, (r)+off_y-tmp_y, bb_width, bb_height, &color);

                BB8_SET_PIXEL_CLAMPED(bb, bb_rotation, (r)+off_x-x, (r)+off_y-tmp_y, bb_width, bb_height, &color);
                BB8_SET_PIXEL_CLAMPED(bb, bb_rotation, (r)+off_x-tmp_y, (r)+off_y-x, bb_width, bb_height, &color);

                BB8_SET_PIXEL_CLAMPED(bb, bb_rotation, (r)+off_x-tmp_y, (h-r)+off_y+x-1, bb_width, bb_height, &color);
                BB8_SET_PIXEL_CLAMPED(bb, bb_rotation, (r)+off_x-x, (h-r)+off_y+tmp_y-1, bb_width, bb_height, &color);
            } else if (bb_type == TYPE_BB8A) {
                const Color8A color = { .a = c, .alpha = 0xFF };

                BB8A_SET_PIXEL_CLAMPED(bb, bb_rotation, (w-r)+off_x+x-1, (h-r)+off_y+tmp_y-1, bb_width, bb_height, &color);
                BB8A_SET_PIXEL_CLAMPED(bb, bb_rotation, (w-r)+off_x+tmp_y-1, (h-r)+off_y+x-1, bb_width, bb_height, &color);

                BB8A_SET_PIXEL_CLAMPED(bb, bb_rotation, (w-r)+off_x+tmp_y-1, (r)+off_y-x, bb_width, bb_height, &color);
                BB8A_SET_PIXEL_CLAMPED(bb, bb_rotation, (w-r)+off_x+x-1, (r)+off_y-tmp_y, bb_width, bb_height, &color);

                BB8A_SET_PIXEL_CLAMPED(bb, bb_rotation, (r)+off_x-x, (r)+off_y-tmp_y, bb_width, bb_height, &color);
                BB8A_SET_PIXEL_CLAMPED(bb, bb_rotation, (r)+off_x-tmp_y, (r)+off_y-x, bb_width, bb_height, &color);

                BB8A_SET_PIXEL_CLAMPED(bb, bb_rotation, (r)+off_x-tmp_y, (h-r)+off_y+x-1, bb_width, bb_height, &color);
                BB8A_SET_PIXEL_CLAMPED(bb, bb_rotation, (r)+off_x-x, (h-r)+off_y+tmp_y-1, bb_width, bb_height, &color);
            } else if (bb_type == TYPE_BBRGB16) {
                const ColorRGB16 color = { .v = RGB_To_RGB16(c, c, c) };

                BBRGB16_SET_PIXEL_CLAMPED(bb, bb_rotation, (w-r)+off_x+x-1, (h-r)+off_y+tmp_y-1, bb_width, bb_height, &color);
                BBRGB16_SET_PIXEL_CLAMPED(bb, bb_rotation, (w-r)+off_x+tmp_y-1, (h-r)+off_y+x-1, bb_width, bb_height, &color);

                BBRGB16_SET_PIXEL_CLAMPED(bb, bb_rotation, (w-r)+off_x+tmp_y-1, (r)+off_y-x, bb_width, bb_height, &color);
                BBRGB16_SET_PIXEL_CLAMPED(bb, bb_rotation, (w-r)+off_x+x-1, (r)+off_y-tmp_y, bb_width, bb_height, &color);

                BBRGB16_SET_PIXEL_CLAMPED(bb, bb_rotation, (r)+off_x-x, (r)+off_y-tmp_y, bb_width, bb_height, &color);
                BBRGB16_SET_PIXEL_CLAMPED(bb, bb_rotation, (r)+off_x-tmp_y, (r)+off_y-x, bb_width, bb_height, &color);

                BBRGB16_SET_PIXEL_CLAMPED(bb, bb_rotation, (r)+off_x-tmp_y, (h-r)+off_y+x-1, bb_width, bb_height, &color);
                BBRGB16_SET_PIXEL_CLAMPED(bb, bb_rotation, (r)+off_x-x, (h-r)+off_y+tmp_y-1, bb_width, bb_height, &color);
            } else if (bb_type == TYPE_BBRGB24) {
                const ColorRGB24 color = { .r = c, .g = c, .b = c };

                BBRGB24_SET_PIXEL_CLAMPED(bb, bb_rotation, (w-r)+off_x+x-1, (h-r)+off_y+tmp_y-1, bb_width, bb_height, &color);
                BBRGB24_SET_PIXEL_CLAMPED(bb, bb_rotation, (w-r)+off_x+tmp_y-1, (h-r)+off_y+x-1, bb_width, bb_height, &color);

                BBRGB24_SET_PIXEL_CLAMPED(bb, bb_rotation, (w-r)+off_x+tmp_y-1, (r)+off_y-x, bb_width, bb_height, &color);
                BBRGB24_SET_PIXEL_CLAMPED(bb, bb_rotation, (w-r)+off_x+x-1, (r)+off_y-tmp_y, bb_width, bb_height, &color);

                BBRGB24_SET_PIXEL_CLAMPED(bb, bb_rotation, (r)+off_x-x, (r)+off_y-tmp_y, bb_width, bb_height, &color);
                BBRGB24_SET_PIXEL_CLAMPED(bb, bb_rotation, (r)+off_x-tmp_y, (r)+off_y-x, bb_width, bb_height, &color);

                BBRGB24_SET_PIXEL_CLAMPED(bb, bb_rotation, (r)+off_x-tmp_y, (h-r)+off_y+x-1, bb_width, bb_height, &color);
                BBRGB24_SET_PIXEL_CLAMPED(bb, bb_rotation, (r)+off_x-x, (h-r)+off_y+tmp_y-1, bb_width, bb_height, &color);
            } else if (bb_type == TYPE_BBRGB32) {
                const ColorRGB32 color = { .r = c, .g = c, .b = c, .alpha = 0xFF };

                BBRGB32_SET_PIXEL_CLAMPED(bb, bb_rotation, (w-r)+off_x+x-1, (h-r)+off_y+tmp_y-1, bb_width, bb_height, &color);  // 7. octant
                BBRGB32_SET_PIXEL_CLAMPED(bb, bb_rotation, (w-r)+off_x+tmp_y-1, (h-r)+off_y+x-1, bb_width, bb_height, &color);  // 8. octant

                BBRGB32_SET_PIXEL_CLAMPED(bb, bb_rotation, (w-r)+off_x+tmp_y-1, (r)+off_y-x, bb_width, bb_height, &color); // 1. octant
                BBRGB32_SET_PIXEL_CLAMPED(bb, bb_rotation, (w-r)+off_x+x-1, (r)+off_y-tmp_y, bb_width, bb_height, &color); // 2. octant

                BBRGB32_SET_PIXEL_CLAMPED(bb, bb_rotation, (r)+off_x-x, (r)+off_y-tmp_y, bb_width, bb_height, &color);  // 3. octant
                BBRGB32_SET_PIXEL_CLAMPED(bb, bb_rotation, (r)+off_x-tmp_y, (r)+off_y-x, bb_width, bb_height, &color);  // 4. octant

                BBRGB32_SET_PIXEL_CLAMPED(bb, bb_rotation, (r)+off_x-tmp_y, (h-r)+off_y+x-1, bb_width, bb_height, &color); // 5. octant
                BBRGB32_SET_PIXEL_CLAMPED(bb, bb_rotation, (r)+off_x-x, (h-r)+off_y+tmp_y-1, bb_width, bb_height, &color); // 6. octant
            }
        }
    }
}

#define setPixelAA_BB8(x, y)     BB8_BLEND_PIXEL_CLAMPED(bb, bb_rotation, x, y, bb_width, bb_height, &color);
#define setPixelAA_BB8A(x, y)    BB8A_BLEND_PIXEL_CLAMPED(bb, bb_rotation, x, y, bb_width, bb_height, &color);
#define setPixelAA_BBRGB16(x, y) BBRGB16_BLEND_PIXEL_CLAMPED(bb, bb_rotation, x, y, bb_width, bb_height, &color);
#define setPixelAA_BBRGB24(x, y) BBRGB24_BLEND_PIXEL_CLAMPED(bb, bb_rotation, x, y, bb_width, bb_height, &color);
#define setPixelAA_BBRGB32(x, y) BBRGB32_BLEND_PIXEL_CLAMPED(bb, bb_rotation, x, y, bb_width, bb_height, &color);

#define BB8_SET_ALL_QUADRANTS(x0, y0, x1, y1)      \
    setPixelAA_BB8(off_x+w-r-1+x1,off_y+r+y1);     \
    setPixelAA_BB8(off_x+r+x0,    off_y+r+y1);     \
    setPixelAA_BB8(off_x+r+x0,    off_y+h-r-1+y0); \
    setPixelAA_BB8(off_x+w-r-1+x1,off_y+h-r-1+y0);

#define BB8A_SET_ALL_QUADRANTS(x0, y0, x1, y1)      \
    setPixelAA_BB8A(off_x+w-r-1+x1,off_y+r+y1);     \
    setPixelAA_BB8A(off_x+r+x0,    off_y+r+y1);     \
    setPixelAA_BB8A(off_x+r+x0,    off_y+h-r-1+y0); \
    setPixelAA_BB8A(off_x+w-r-1+x1,off_y+h-r-1+y0);

#define BBRGB16_SET_ALL_QUADRANTS(x0, y0, x1, y1)      \
    setPixelAA_BBRGB16(off_x+w-r-1+x1,off_y+r+y1);     \
    setPixelAA_BBRGB16(off_x+r+x0,    off_y+r+y1);     \
    setPixelAA_BBRGB16(off_x+r+x0,    off_y+h-r-1+y0); \
    setPixelAA_BBRGB16(off_x+w-r-1+x1,off_y+h-r-1+y0);

#define BBRGB24_SET_ALL_QUADRANTS(x0, y0, x1, y1)      \
    setPixelAA_BBRGB24(off_x+w-r-1+x1,off_y+r+y1);     \
    setPixelAA_BBRGB24(off_x+r+x0,    off_y+r+y1);     \
    setPixelAA_BBRGB24(off_x+r+x0,    off_y+h-r-1+y0); \
    setPixelAA_BBRGB24(off_x+w-r-1+x1,off_y+h-r-1+y0);

#define BBRGB32_SET_ALL_QUADRANTS(x0, y0, x1, y1)      \
    setPixelAA_BBRGB32(off_x+w-r-1+x1,off_y+r+y1);     \
    setPixelAA_BBRGB32(off_x+r+x0,    off_y+r+y1);     \
    setPixelAA_BBRGB32(off_x+r+x0,    off_y+h-r-1+y0); \
    setPixelAA_BBRGB32(off_x+w-r-1+x1,off_y+h-r-1+y0);

void BB_paint_rounded_corner_AA_1px(BlitBuffer * restrict bb, unsigned int off_x, unsigned int off_y, unsigned int w, unsigned int h, int r, uint8_t c) { // draw a black anti-aliased circle with thickness 1
    const int bb_type = GET_BB_TYPE(bb);
    const int bb_rotation = GET_BB_ROTATION(bb);
    const unsigned int bb_width = BB_GET_WIDTH(bb);
    const unsigned int bb_height = BB_GET_HEIGHT(bb);

    int x = -r, y = 0;
    int i, err = 2-2*r;                             // error of 1.step
    int x2, e2;
    r = 1-err;
    do {
        i = 255*abs(err-2*(x+y)-2)/r;               // get blend value of pixel

        if (bb_type == TYPE_BB8) {
            const Color8A color = { .a = c, .alpha = 255-i };
            BB8_SET_ALL_QUADRANTS(-(r/2)+x, (r/2)+y, (r/2)-x, -(r/2)-y);
        } else if (bb_type == TYPE_BB8A) {
            const Color8A color = { .a = c, .alpha = 255-i };
            BB8A_SET_ALL_QUADRANTS(-(r/2)+x, (r/2)+y, (r/2)-x, -(r/2)-y);
        } else if (bb_type == TYPE_BBRGB16) {
            const Color8A color = { .a = c, .alpha = 255-i };
            BBRGB16_SET_ALL_QUADRANTS(-(r/2)+x, (r/2)+y, (r/2)-x, -(r/2)-y);
        } else if (bb_type == TYPE_BBRGB24) {
            const ColorRGB32 color = { .r = c, .g = c, .b = c, .alpha = 255-i };
            BBRGB24_SET_ALL_QUADRANTS(-(r/2)+x, (r/2)+y, (r/2)-x, -(r/2)-y);
        } else if (bb_type == TYPE_BBRGB32) {
            const ColorRGB32 color = { .r = c, .g = c, .b = c, .alpha = 255-i };
            BBRGB32_SET_ALL_QUADRANTS(-(r/2)+x, (r/2)+y, (r/2)-x, -(r/2)-y);
        }
        e2 = err;
        x2 = x; // remember values
        if (err+y > 0) {
            i = 255*(err-2*x-1)/r; // outward pixel
            if (i < 256) {
                if (bb_type == TYPE_BB8) {
                    const Color8A color = { .a = c, .alpha = 255-i };
                    BB8_SET_ALL_QUADRANTS(-(r/2)+x, (r/2)+1+y, (r/2)-x, -(r/2)-1-y);
                } else if (bb_type == TYPE_BB8A) {
                    const Color8A color = { .a = c, .alpha = 255-i };
                    BB8A_SET_ALL_QUADRANTS(-(r/2)+x, (r/2)+1+y, (r/2)-x, -(r/2)-1-y);
                } else if (bb_type == TYPE_BBRGB16) {
                    const Color8A color = { .a = c, .alpha = 255-i };
                    BBRGB16_SET_ALL_QUADRANTS(-(r/2)+x, (r/2)+1+y, (r/2)-x, -(r/2)-1-y);
                } else if (bb_type == TYPE_BBRGB24) {
                    const ColorRGB32 color = { .r = c, .g = c, .b = c, .alpha = 255-i };
                    BBRGB24_SET_ALL_QUADRANTS(-(r/2)+x, (r/2)+1+y, (r/2)-x, -(r/2)-1-y);
                } else if (bb_type == TYPE_BBRGB32) {
                    const ColorRGB32 color = { .r = c, .g = c, .b = c, .alpha = 255-i };
                    BBRGB32_SET_ALL_QUADRANTS(-(r/2)+x, (r/2)+1+y, (r/2)-x, -(r/2)-1-y);
                }
            }
            ++x;
            err += x*2+1;
        }
        if (e2+x2 <= 0) { // y step
            i = 255*(2*y+3-e2)/r; // inward pixel
            if (i < 256) {
                if (bb_type == TYPE_BB8) {
                    const Color8A color = { .a = c, .alpha = 255-i };
                    BB8_SET_ALL_QUADRANTS(-(r/2)+x, (r/2)+y, (r/2)-x, -(r/2)-y);
                } else if (bb_type == TYPE_BB8A) {
                    const Color8A color = { .a = c, .alpha = 255-i };
                    BB8A_SET_ALL_QUADRANTS(-(r/2)+x, (r/2)+y, (r/2)-x, -(r/2)-y);
                } else if (bb_type == TYPE_BBRGB16) {
                    const Color8A color = { .a = c, .alpha = 255-i };
                    BBRGB16_SET_ALL_QUADRANTS(-(r/2)+x, (r/2)+y, (r/2)-x, -(r/2)-y);
                } else if (bb_type == TYPE_BBRGB24) {
                    const ColorRGB32 color = { .r = c, .g = c, .b = c, .alpha = 255-i };
                    BBRGB24_SET_ALL_QUADRANTS(-(r/2)+x, (r/2)+y, (r/2)-x, -(r/2)-y);
                } else if (bb_type == TYPE_BBRGB32) {
                    const ColorRGB32 color = { .r = c, .g = c, .b = c, .alpha = 255-i };
                    BBRGB32_SET_ALL_QUADRANTS(-(r/2)+x, (r/2)+y, (r/2)-x, -(r/2)-y);
                }
            }
            ++y;
            err += y*2+1;
        }
    } while (x < 0);
}

void BB_paint_rounded_corner_AA(BlitBuffer * restrict bb, unsigned int off_x, unsigned int off_y, unsigned int w, unsigned int h, int bw, int r, uint8_t c )
{        // draw a black anti-aliased circle with width bw
    const int bb_type = GET_BB_TYPE(bb);
    const int bb_rotation = GET_BB_ROTATION(bb);
    const unsigned int bb_width = BB_GET_WIDTH(bb);
    const unsigned int bb_height = BB_GET_HEIGHT(bb);

    int x0 = -r;
    int y0 = -r;
    int x1 = r;
    int y1 = r;

    int o_diam = 2*r; // outer diameter
    int odd_diam = o_diam&1; // odd diameter
    int a2 = 2*r-2*bw;
    int dx = 4*(o_diam-1)*o_diam*o_diam;
    int dy = 4*(odd_diam-1)*o_diam*o_diam;                // error increment
    int i = o_diam+a2;
    int err = odd_diam*o_diam*o_diam;
    int dx2, dy2, e2, ed;

    if ((bw-1)*(2*o_diam-bw) > o_diam*o_diam) {
        a2 = 0;
        bw = o_diam/2;
    }

    if (x0 > x1) {
        x0 = x1;
        x1 += o_diam;
    }        // if called with swapped points
    if (y0 > y1)
        y0 = y1;                                  // .. exchange them
    if (a2 <= 0)
        bw = o_diam;                                     // filled ellipse
    e2 = bw;
    bw = x0+bw-e2;
    dx2 = 4*(a2+2*e2-1)*a2*a2;
    dy2 = 4*(odd_diam-1)*a2*a2;
    e2 = dx2*e2;
    y0 += (o_diam+1)>>1;
    y1 = y0-odd_diam;                              // starting pixel
    int a1;
    a1 = 8*o_diam*o_diam;
    a2 = 8*a2*a2;

    do {
        for (;;) {
            if (err < 0 || x0 > x1) {
                i = x0;
                break;
            }
            i = MIN(dx,dy);
            ed = MAX(dx,dy);

            ed += 2*ed*i*i/(4*ed*ed+i*i+1)+1;// approx ed=sqrt(dx*dx+dy*dy)

            i = 255*err/ed;                             // outside anti-aliasing
            if (bb_type == TYPE_BB8) {
                const Color8A color = { .a = c, .alpha = 255-i };
                BB8_SET_ALL_QUADRANTS(x0, y0, x1, y1);
            } else if (bb_type == TYPE_BB8A) {
                const Color8A color = { .a = c, .alpha = 255-i };
                BB8A_SET_ALL_QUADRANTS(x0, y0, x1, y1);
            } else if (bb_type == TYPE_BBRGB16) {
                const Color8A color = { .a = c, .alpha = 255-i };
                BBRGB16_SET_ALL_QUADRANTS(x0, y0, x1, y1);
            } else if (bb_type == TYPE_BBRGB24) {
                const ColorRGB32 color = { .r = c, .g = c, .b = c, .alpha = 255-i };
                BBRGB24_SET_ALL_QUADRANTS(x0, y0, x1, y1);
            } else if (bb_type == TYPE_BBRGB32) {
                const ColorRGB32 color = { .r = c, .g = c, .b = c, .alpha = 255-i };
                BBRGB32_SET_ALL_QUADRANTS(x0, y0, x1, y1);
            }

            if (err+dy+a1 < dx) {
                i = x0+1;
                break;
            }
            x0++;
            x1--;
            err -= dx;
            dx -= a1;  // x error increment
        }
        for (; i < bw && 2*i <= x0+x1; i++) {  // fill line pixel
            if (bb_type == TYPE_BB8) {
                const Color8A color = { .a = c, .alpha = 255 };
                BB8_SET_ALL_QUADRANTS(i, y0, x0+x1-i, y1);
            } else if (bb_type == TYPE_BB8A) {
                const Color8A color = { .a = c, .alpha = 255 };
                BB8A_SET_ALL_QUADRANTS(i, y0, x0+x1-i, y1);
            } else if (bb_type == TYPE_BBRGB16) {
                const Color8A color = { .a = c, .alpha = 255 };
                BBRGB16_SET_ALL_QUADRANTS(i, y0, x0+x1-i, y1);
            } else if (bb_type == TYPE_BBRGB24) {
                const ColorRGB32 color = { .r = c, .g = c, .b = c, .alpha = 255};
                BBRGB24_SET_ALL_QUADRANTS(i, y0, x0+x1-i, y1);
            } else if (bb_type == TYPE_BBRGB32) {
                const ColorRGB32 color = { .r = c, .g = c, .b = c, .alpha = 255};
                BBRGB32_SET_ALL_QUADRANTS(i, y0, x0+x1-i, y1);
            }
        }
        while (e2 > 0 && x0+x1 >= 2*bw) {               // inside anti-aliasing
            i = MIN(dx2,dy2);
            ed = MAX(dx2,dy2);

            ed += 2*ed*i*i/(4*ed*ed+i*i);                 // approximation

            i = 255-255*e2/ed;             // get intensity value by pixel error
            if (bb_type == TYPE_BB8) {
                const Color8A color = { .a = c, .alpha = 255-i };
                BB8_SET_ALL_QUADRANTS(bw, y0, x0+x1-bw, y1);
            } else if (bb_type == TYPE_BB8A) {
                const Color8A color = { .a = c, .alpha = 255-i };
                BB8A_SET_ALL_QUADRANTS(bw, y0, x0+x1-bw, y1);
            } else if (bb_type == TYPE_BBRGB16) {
                const Color8A color = { .a = c, .alpha = 255-i };
                BBRGB16_SET_ALL_QUADRANTS(bw, y0, x0+x1-bw, y1);
            } else if (bb_type == TYPE_BBRGB24) {
                const ColorRGB32 color = { .r = c, .g = c, .b = c, .alpha = 255-i };
                BBRGB24_SET_ALL_QUADRANTS(bw, y0, x0+x1-bw, y1);
            } else if (bb_type == TYPE_BBRGB32) {
                const ColorRGB32 color = { .r = c, .g = c, .b = c, .alpha = 255-i };
                BBRGB32_SET_ALL_QUADRANTS(bw, y0, x0+x1-bw, y1);
            }
            if (e2+dy2+a2 < dx2)
                break;
            bw++;
            e2 -= dx2;
            dx2 -= a2; // x error increment
        }
        dy2 += a2;
        e2 += dy2;
        dy += a1;    // y step
        err += dy;
        y0++;
        y1--;
    } while (x0 < x1);

    if (y0-y1 <= o_diam)
    {
        if (err > dy+a1) {
            y0--;
            y1++;
            dy -= a1;
            err -= dy;
        }
        for (; y0-y1 <= o_diam; err += dy += a1) { // too early stop of flat ellipses
            i = 255*4*err/a1;  // -> finish tip of ellipse
            if (bb_type == TYPE_BB8) {
                const Color8A color = { .a = c, .alpha = 255-i };
                BB8_SET_ALL_QUADRANTS(x0, y0, x1, y1);
            } else if (bb_type == TYPE_BB8A) {
                const Color8A color = { .a = c, .alpha = 255-i };
                BB8A_SET_ALL_QUADRANTS(x0, y0, x1, y1);
            } else if (bb_type == TYPE_BBRGB16) {
            const Color8A color = { .a = c, .alpha = 255-i };
                BBRGB16_SET_ALL_QUADRANTS(x0, y0, x1, y1);
            } else if (bb_type == TYPE_BBRGB24) {
                const ColorRGB32 color = { .r = c, .g = c, .b = c, .alpha = 255-i };
                BBRGB24_SET_ALL_QUADRANTS(x0, y0, x1, y1);
            } else if (bb_type == TYPE_BBRGB32) {
                const ColorRGB32 color = { .r = c, .g = c, .b = c, .alpha = 255-i };
                BBRGB32_SET_ALL_QUADRANTS(x0, y0, x1, y1);
            }
            ++y0;
            --y1;
        }
    }
}
