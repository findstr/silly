#ifndef _FLIPBUF_H
#define _FLIPBUF_H

#include <stdint.h>
#include <stddef.h>
#include "array.h"
#include "spinlock.h"

struct flipbuf {
	int writing;
	struct array slots[2];
	spinlock_t lock;
};

static inline void flipbuf_init(struct flipbuf *fb)
{
	fb->writing = 0;
	array_init(&fb->slots[0], 16);
	array_init(&fb->slots[1], 16);
	spinlock_init(&fb->lock);
}

static inline void flipbuf_destroy(struct flipbuf *fb)
{
	array_destroy(&fb->slots[0]);
	array_destroy(&fb->slots[1]);
	spinlock_destroy(&fb->lock);
}

static inline int flipbuf_write(struct flipbuf *fb, const uint8_t *data, int size)
{
	int was_empty;
	struct array *arr;
	spinlock_lock(&fb->lock);
	arr = &fb->slots[fb->writing];
	was_empty = arr->size == 0;
	array_write(arr, data, size);
	spinlock_unlock(&fb->lock);
	return was_empty;
}

static inline struct array *flipbuf_flip(struct flipbuf *fb)
{
	struct array *arr;
	array_clear(&fb->slots[!fb->writing]);
	spinlock_lock(&fb->lock);
	arr = &fb->slots[fb->writing];
	fb->writing = !fb->writing;
	spinlock_unlock(&fb->lock);
	return arr;
}

#endif