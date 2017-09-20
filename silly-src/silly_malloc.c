#include "atomic.h"
#include "silly_malloc.h"

#if defined(USE_JEMALLOC)
#include <jemalloc/jemalloc.h>
#elif defined(__linux__)
#include <malloc.h>
#elif defined(__macosx__)
#include <malloc/malloc.h>
#endif

static size_t allocsize = 0;

#if defined(USE_JEMALLOC)

#define MALLOC je_malloc
#define REALLOC je_realloc
#define	FREE je_free

#else

#define MALLOC malloc
#define REALLOC realloc
#define	FREE free

#endif

static inline size_t
xalloc_usable_size(void *ptr)
{
#if defined(USE_JEMALLOC)
	return je_malloc_usable_size(ptr);
#elif defined(__linux__)
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
	void *ptr = MALLOC(sz);
	int real = xalloc_usable_size(ptr);
	atomic_add(&allocsize, real);
	return ptr;
}

void *
silly_realloc(void *ptr, size_t sz)
{
	size_t realo = xalloc_usable_size(ptr);
	ptr = REALLOC(ptr, sz);
	size_t realn = xalloc_usable_size(ptr);
	if (realo > realn)	//shrink
		atomic_sub(&allocsize, realo - realn);
	else
		atomic_add(&allocsize, realn - realo);
	return ptr;
}

void
silly_free(void *ptr)
{
	size_t real = xalloc_usable_size(ptr);
	atomic_sub(&allocsize, real);
	FREE(ptr);
}

size_t
silly_memstatus()
{
	return allocsize;
}

