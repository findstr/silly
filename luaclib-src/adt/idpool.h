#ifndef SILLY_ADT_IDPOOL_H
#define SILLY_ADT_IDPOOL_H

#include "stack.h"
#include "bitmask.h"

struct id_pool {
	struct stack freelist;
	int max_id;
#ifdef SILLY_TEST
	struct bitmask allocated;  /* 仅在测试模式下启用 */
#endif
};

static inline void id_pool_init(struct id_pool *p)
{
	stack_init(&p->freelist);
	p->max_id = 0;
#ifdef SILLY_TEST
	bitmask_init(&p->allocated);
#endif
}

static inline int id_pool_alloc(struct id_pool *p)
{
	int id;
	if (stack_empty(&p->freelist)) {
		id = ++p->max_id;
	} else {
		id = stack_pop(&p->freelist);
	}
#ifdef SILLY_TEST
	bitmask_set(&p->allocated, id - 1);  /* ID从1开始，bit从0开始 */
#endif

	return id;
}

static inline int id_pool_free(struct id_pool *p, int id)
{
	if (id < 1 || id > p->max_id) {
		return -1;  /* ID越界 */
	}

#ifdef SILLY_TEST
	/* 测试模式：检测double free */
	if (!bitmask_test(&p->allocated, id - 1)) {
		return -1;  /* Double free detected */
	}
	bitmask_clear(&p->allocated, id - 1);
#endif

	stack_push(&p->freelist, id);
	return 0;
}

static inline void id_pool_destroy(struct id_pool *p)
{
	stack_destroy(&p->freelist);
#ifdef SILLY_TEST
	bitmask_destroy(&p->allocated);
#endif
	p->max_id = 0;
}

#endif