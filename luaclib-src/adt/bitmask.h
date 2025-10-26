#ifndef SILLY_ADT_BITMASK_H
#define SILLY_ADT_BITMASK_H

#include <assert.h>
#include <stdint.h>
#include <string.h>

#include "silly.h"

struct bitmask {
	uint32_t *bits;
	int capacity;
};

static inline void bitmask_init(struct bitmask *bm)
{
	bm->bits = NULL;
	bm->capacity = 0;
}

static inline void bitmask_reserve(struct bitmask *bm, int max_bit)
{
	int new_cap = (max_bit + 31) & ~31;
	if (new_cap <= bm->capacity)
		return;
	int old_size = (bm->capacity + 31) / 32;
	int new_size = new_cap / 32;
	bm->bits = (uint32_t *)silly_realloc(bm->bits, new_size * sizeof(uint32_t));
	if (new_size > old_size) {
		memset(bm->bits + old_size, 0, (new_size - old_size) * sizeof(uint32_t));
	}
	bm->capacity = new_cap;
}

static inline void bitmask_set(struct bitmask *bm, int bit)
{
	assert(bit >= 0);
	if (bit >= bm->capacity) {
		bitmask_reserve(bm, bit+1);
	}
	int idx = bit / 32;
	int offset = bit % 32;
	bm->bits[idx] |= (1u << offset);
}

static inline void bitmask_clear(struct bitmask *bm, int bit)
{
	assert(bit >= 0 && bit < bm->capacity);
	int idx = bit / 32;
	int offset = bit % 32;
	bm->bits[idx] &= ~(1u << offset);
}

static inline int bitmask_test(struct bitmask *bm, int bit)
{
	if (bit < 0 || bit >= bm->capacity) {
		return 0;
	}
	int idx = bit / 32;
	int offset = bit % 32;
	return (bm->bits[idx] & (1u << offset)) != 0;
}

static inline void bitmask_destroy(struct bitmask *bm)
{
	if (bm->bits) {
		silly_free(bm->bits);
		bm->bits = NULL;
	}
	bm->capacity = 0;
}

#endif