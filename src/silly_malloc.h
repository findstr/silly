#ifndef _SILLY_MALLOC_H
#define _SILLY_MALLOC_H

#include <stdlib.h>

void *mem_alloc(size_t sz);
void *mem_realloc(void *ptr, size_t sz);
void mem_free(void *ptr);
int mem_mallctl(const char *name, void *oldp, size_t *oldlenp, void *newp,
		size_t newlen);

const char *mem_allocator();
size_t mem_used();
size_t mem_rss();

#endif
