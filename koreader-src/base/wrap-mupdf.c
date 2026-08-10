/*
    KindlePDFViewer: MuPDF abstraction for Lua
    Copyright (C) 2011 Hans-Werner Hilse <hilse@web.de>

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
#include <stdbool.h>
#include <stdlib.h>
#include <math.h>
#include <stddef.h>
#include "wrap-mupdf.h"

enum {
    MAGIC = 0x3795d42b,
};

typedef struct header {
    int magic;
    size_t sz;
} header;

static size_t msize = 0U;

static inline bool
alloc_total_size(size_t size, size_t *total)
{
    if (size > (size_t)-1 - sizeof(header)) {
        return false;
    }
    *total = size + sizeof(header);
    return true;
}

static void *
my_malloc_default(void *opaque, size_t size)
{
    size_t total;
    if (!alloc_total_size(size, &total)) {
        return NULL;
    }

    struct header * h = malloc(total);
    if (h == NULL) {
        return NULL;
    }

    h->magic = MAGIC;
    h->sz = size;
    msize += total;
    return (void *)(h + 1);
}

static void
my_free_default(void *opaque, void *ptr)
{
#if 0
    fprintf(stderr, "free %p (%zu)\n", ptr, msize);
#endif
    if (ptr != NULL) {
        struct header * h = ((struct header *)ptr) - 1;
        if (h->magic != MAGIC) { /* Not allocated by us */
            fprintf(stderr, "attempt to free something that doesn't belong to us!\n");
        } else {
            msize -= h->sz + sizeof(struct header);
            free(h);
        }
    }
}

static void *
my_realloc_default(void *opaque, void *old, size_t size)
{
    if (old == NULL) { //practically, it's a malloc
        return my_malloc_default(opaque, size);
    }

    if (size == 0) {
        my_free_default(opaque, old);
        return NULL;
    }

    struct header * h = ((struct header *)old) - 1;
    if (h->magic != MAGIC) { // Not allocated by my_malloc_default
        //printf("§§§ warn: not allocated by my_malloc_default, new size: %zu\n", size);
        return realloc(old, size);
    }

    size_t total;
    if (!alloc_total_size(size, &total)) {
        return NULL;
    }

    const size_t old_total = h->sz + sizeof(header);
    struct header * newh = realloc(h, total);
    if (newh == NULL) {
        return NULL;
    }

    newh->magic = MAGIC;
    newh->sz = size;
    if (total >= old_total) {
        msize += total - old_total;
    } else {
        msize -= old_total - total;
    }
    return (void *)(newh + 1);
}

fz_alloc_context my_alloc_default =
{
    NULL,
    my_malloc_default,
    my_realloc_default,
    my_free_default
};

fz_alloc_context* mupdf_get_my_alloc_context() {
    return &my_alloc_default;
}

int mupdf_get_cache_size() {
    return msize;
}

int mupdf_error_code(fz_context *ctx) {
    return ctx->error.errcode;
}
char* mupdf_error_message(fz_context *ctx) {
    return ctx->error.message;
}

fz_matrix *mupdf_fz_scale(fz_matrix *m, float sx, float sy) {
    *m = fz_scale(sx, sy);
    return m;
}

fz_matrix *mupdf_fz_translate(fz_matrix *m, float tx, float ty) {
    *m = fz_translate(tx, ty);
    return m;
}

fz_matrix *mupdf_fz_pre_rotate(fz_matrix *m, float theta) {
    *m = fz_pre_rotate(*m, theta);
    return m;
}

fz_matrix *mupdf_fz_pre_translate(fz_matrix *m, float tx, float ty) {
    *m = fz_pre_translate(*m, tx, ty);
    return m;
}

fz_rect *mupdf_fz_transform_rect(fz_rect *r, const fz_matrix *m) {
    *r = fz_transform_rect(*r, *m);
    return r;
}

fz_irect *mupdf_fz_round_rect(fz_irect *ir, const fz_rect *r) {
    *ir = fz_round_rect(*r);
    return ir;
}

fz_rect *mupdf_fz_union_rect(fz_rect *a, const fz_rect *b) {
    *a = fz_union_rect(*a, *b);
    return a;
}

fz_rect *mupdf_fz_rect_from_quad(fz_rect *r, const fz_quad *q) {
    *r = fz_rect_from_quad(*q);
    return r;
}

fz_rect *mupdf_fz_bound_page(fz_context *ctx, fz_page *page, fz_rect *r) {
    *r = fz_bound_page(ctx, page);
    return r;
}

/* wrappers for functions that throw exceptions mupdf-style (setjmp/longjmp) */

#define MUPDF_DO_WRAP
#include "wrap-mupdf.h"
