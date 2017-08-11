#include "silly_malloc.h"

#if defined(__linux__)
#include <malloc.h>
#elif defined(__macosx__)
#include <malloc/malloc.h>
#endif

static size_t allocsize = 0;

static inline size_t
xalloc_usable_size(void *ptr)
{
#if defined(__linux__)
	return malloc_usable_size(ptr);
#elif defined(__macosx__)
	return malloc_size(ptr);
#else
	return 0;
#endif
}

void *
silly_malloc(size_t sz)
{
	void *ptr = malloc(sz);
	int real = xalloc_usable_size(ptr);
	__sync_fetch_and_add(&allocsize, real);
	return ptr;
}

void *
silly_realloc(void *ptr, size_t sz)
{
	size_t realo = xalloc_usable_size(ptr);
	ptr = realloc(ptr, sz);
	size_t realn = xalloc_usable_size(ptr);
	if (realo > realn)	//shrink
		__sync_fetch_and_sub(&allocsize, realo - realn);
	else
		__sync_fetch_and_add(&allocsize, realn - realo);
	return ptr;
}

void
silly_free(void *ptr)
{
	size_t real = xalloc_usable_size(ptr);
	__sync_fetch_and_sub(&allocsize, real);
	free(ptr);
}

size_t
silly_memstatus()
{
	return allocsize;
}

