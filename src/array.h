#ifndef _ARRAY_H
#define _ARRAY_H

#include <stdint.h>
#include <string.h>
#include <stdatomic.h>

#include "mem.h"

struct array {
	int32_t cap;
	int32_t size;
	void *buf;
};

static inline void array_init(struct array *a, int cap)
{
	if (cap == 0)
		cap = 16;
	a->cap = cap;
	a->size = 0;
	a->buf = mem_alloc(cap);
}

static inline void array_write(struct array *a, const uint8_t *data, int size)
{
	if (a->size + size > a->cap) {
		int new_cap = a->cap * 2;
		while (new_cap < a->size + size)
			new_cap *= 2;
		a->buf = mem_realloc(a->buf, new_cap);
		a->cap = new_cap;
	}
	memcpy((uint8_t *)a->buf + a->size, data, size);
	a->size += size;
}

static inline void array_clear(struct array *a)
{
	a->size = 0;
}

static inline void array_destroy(struct array *a)
{
	mem_free(a->buf);
	a->cap = 0;
	a->size = 0;
	a->buf = NULL;
}

#endif