#ifndef _CMD_BUF_H_
#define _CMD_BUF_H_

#include <stdint.h>
#include "array.h"
#include "spinlock.h"

struct cmdbuf {
	int cmdwriting;
	struct array slots[2];
	spinlock_t cmdlock;
};

static inline void cmdbuf_init(struct cmdbuf *cb, int cap)
{
	cb->cmdwriting = 0;
	array_init(&cb->slots[0], cap);
	array_init(&cb->slots[1], cap);
	spinlock_init(&cb->cmdlock);
}

static inline void cmdbuf_destroy(struct cmdbuf *cb)
{
	array_free(&cb->slots[0]);
	array_free(&cb->slots[1]);
}

static inline int cmdbuf_append(struct cmdbuf *cb, uint8_t *data, int size)
{
	int first;
	struct array *arr;
	spinlock_lock(&cb->cmdlock);
	arr = &cb->slots[cb->cmdwriting];
	first = arr->size == 0;
	array_append(arr, data, size);
	spinlock_unlock(&cb->cmdlock);
	return first;
}

static inline struct array *cmdbuf_flip(struct cmdbuf *cb)
{
	struct array *arr;
	spinlock_lock(&cb->cmdlock);
	arr = &cb->slots[cb->cmdwriting];
	cb->cmdwriting = 1 - cb->cmdwriting;
	cb->slots[cb->cmdwriting].size = 0;
	spinlock_unlock(&cb->cmdlock);
	return arr;
}


#endif