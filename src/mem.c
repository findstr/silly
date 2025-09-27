#include <unistd.h>
#include <stdio.h>
#include <fcntl.h>
#include <string.h>
#include <stdatomic.h>

#include "silly.h"
#include "platform.h"
#include "mem.h"

#ifndef DISABLE_JEMALLOC
#include <jemalloc/jemalloc.h>
#endif

static atomic_ptrdiff_t allocsize = 0;

#ifndef DISABLE_JEMALLOC

#define MALLOC je_malloc
#define REALLOC je_realloc
#define FREE je_free

#else

#define MALLOC malloc
#define REALLOC realloc
#define FREE free

#endif

static inline size_t xalloc_usable_size(void *ptr)
{
#ifndef DISABLE_JEMALLOC
	return je_malloc_usable_size(ptr);
#else
	return libc_malloc_usable_size(ptr);
#endif
}

void *mem_alloc(size_t sz)
{
	void *ptr = MALLOC(sz);
#ifdef SILLY_TEST
	memset(ptr, 0, sz);
#endif
	int real = xalloc_usable_size(ptr);
	atomic_fetch_add_explicit(&allocsize, real, memory_order_relaxed);
	return ptr;
}

void *mem_realloc(void *ptr, size_t sz)
{
	ssize_t realo = xalloc_usable_size(ptr);
	ptr = REALLOC(ptr, sz);
	ssize_t realn = xalloc_usable_size(ptr);
	atomic_fetch_add_explicit(&allocsize, realn - realo,
				  memory_order_relaxed);
	return ptr;
}

void mem_free(void *ptr)
{
	size_t real = xalloc_usable_size(ptr);
	atomic_fetch_sub_explicit(&allocsize, real, memory_order_relaxed);
	FREE(ptr);
}

#define BUILD(name, MAJOR, MINOR) (name "-" STR(MAJOR) "." STR(MINOR))

const char *mem_allocator()
{
#ifndef DISABLE_JEMALLOC
	return BUILD("jemalloc", JEMALLOC_VERSION_MAJOR,
		     JEMALLOC_VERSION_MINOR);
#else
	return "libc";
#endif
}

int mem_mallctl(const char *name, void *oldp, size_t *oldlenp, void *newp,
		size_t newlen)
{
	(void)name;
	(void)oldp;
	(void)oldlenp;
	(void)newp;
	(void)newlen;
#ifdef DISABLE_JEMALLOC
	memset(oldp, 0, *oldlenp);
	return 0;
#else
	return je_mallctl(name, oldp, oldlenp, newp, newlen);
#endif
}

size_t mem_used()
{
	return atomic_load_explicit(&allocsize, memory_order_relaxed);
}

//Resident Set Size
size_t mem_rss()
{
#if defined(memory_rss)
	return memory_rss();
#else
	return atomic_load_explicit(&allocsize, memory_order_relaxed);
#endif
}
