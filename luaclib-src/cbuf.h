#ifndef _CBUF_H
#define _CBUF_H

#include <stddef.h>
#include <string.h>
#include <assert.h>
#include "silly.h"

/* Use LUAL_BUFFERSIZE as default (from Lua) */
#ifndef CBUF_INIT_SIZE
#define CBUF_INIT_SIZE LUAL_BUFFERSIZE
#endif

/* Generic growable buffer with inline storage */
struct cbuf {
	char *data;
	size_t len;
	size_t cap;
	char b[CBUF_INIT_SIZE];
};

/* Initialize buffer to use inline storage */
static inline void cbuf_init(struct cbuf *b)
{
	b->data = b->b;
	b->len = 0;
	b->cap = CBUF_INIT_SIZE;
}

/* Free dynamic storage if allocated */
static inline void cbuf_free(struct cbuf *b)
{
	if (b->data != NULL && b->data != b->b) {
		silly_free(b->data);
		b->data = NULL;
	}
}

/* Ensure capacity for 'need' additional bytes */
static inline void cbuf_ensure(struct cbuf *b, size_t need)
{
	size_t newcap = b->cap;
	while (newcap < b->len + need)
		newcap *= 2;
	if (newcap == b->cap)
		return;
	if (b->data == b->b) {
		b->data = (char *)silly_malloc(newcap);
		memcpy(b->data, b->b, b->len);
	} else {
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

#endif  /* _CBUF_H */
