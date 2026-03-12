/*
 * Generic growable buffer with optional inline storage.
 *
 * Define exactly ONE before including:
 *   CBUF_INLINE_SIZE  - struct embeds char[N], avoids heap for small data
 *   CBUF_INIT_SIZE    - pure heap mode, first malloc is N bytes
 */
#ifndef _CBUF_H
#define _CBUF_H

#include <stddef.h>
#include <string.h>
#include <assert.h>
#include "silly.h"

#if defined(CBUF_INLINE_SIZE) && defined(CBUF_INIT_SIZE)
#error "Define CBUF_INLINE_SIZE or CBUF_INIT_SIZE, not both"
#elif defined(CBUF_INLINE_SIZE)
#define CBUF_USE_INLINE
#define CBUF_INIT_SIZE CBUF_INLINE_SIZE
#define CBUF_INLINE_BUF(buf) ((buf)->b)
#elif defined(CBUF_INIT_SIZE)
#define CBUF_INLINE_BUF(buf) ((void)(buf), NULL)
#else
#error "Define CBUF_INLINE_SIZE or CBUF_INIT_SIZE before including cbuf.h"
#endif

/* Generic growable buffer with optional inline storage */
struct cbuf {
	char *data;
	size_t len;
	size_t cap;
#ifdef CBUF_USE_INLINE
	char b[CBUF_INIT_SIZE];
#endif
};

/* Initialize buffer (lazy allocation when not using inline) */
static inline void cbuf_init(struct cbuf *b)
{
	b->len = 0;
#ifdef CBUF_USE_INLINE
	b->data = b->b;
	b->cap = CBUF_INIT_SIZE;
#else
	b->data = NULL;  /* lazy allocation on first use */
	b->cap = 0;
#endif
}

/* Free dynamic storage if allocated */
static inline void cbuf_free(struct cbuf *b)
{
	if (b->data != NULL && b->data != CBUF_INLINE_BUF(b)) {
		silly_free(b->data);
		b->data = NULL;
		b->cap = 0;
	}
}

/* Ensure capacity for 'need' additional bytes */
static inline void cbuf_ensure(struct cbuf *b, size_t need)
{
	if (b->len + need <= b->cap)
		return;
	size_t newcap = b->cap;
#ifndef CBUF_USE_INLINE
	if (newcap == 0)
		newcap = CBUF_INIT_SIZE;
#endif
	while (newcap < b->len + need)
		newcap *= 2;

#ifdef CBUF_USE_INLINE
	if (b->data == b->b) {
		/* Growing from inline to heap */
		b->data = (char *)silly_malloc(newcap);
		memcpy(b->data, b->b, b->len);
	} else
#endif
	{
		/* realloc(NULL, size) behaves like malloc(size) */
		b->data = (char *)silly_realloc(b->data, newcap);
	}
	b->cap = newcap;
}

/* Add single character */
static inline void cbuf_addchar(struct cbuf *b, char ch)
{
	cbuf_ensure(b, 1);
	b->data[b->len++] = ch;
}

/* Add string */
static inline void cbuf_addlstr(struct cbuf *b, const char *s, size_t n)
{
	cbuf_ensure(b, n);
	memcpy(b->data + b->len, s, n);
	b->len += n;
}

/* Remove n bytes from end */
static inline void cbuf_pop(struct cbuf *b, size_t n)
{
	if (n > b->len)
		n = b->len;
	b->len -= n;
}

/* Reset to empty, keep allocated storage */
static inline void cbuf_reset(struct cbuf *b)
{
	b->len = 0;
}

/* Direct access for snprintf - get pointer to write at current position */
static inline char *cbuf_prepbuffsize(struct cbuf *b, size_t need)
{
	cbuf_ensure(b, need);
	return b->data + b->len;
}

/* Advance length after direct write (e.g., after snprintf) */
static inline void cbuf_addsize(struct cbuf *b, size_t n)
{
	b->len += n;
}

#endif  /* _CBUF_H */
