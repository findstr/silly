#include <unistd.h>
#include <stdio.h>
#include <fcntl.h>
#include <string.h>
#include "atomic.h"
#include "silly.h"
#include "silly_malloc.h"

#ifndef DISABLE_JEMALLOC
#include <jemalloc/jemalloc.h>
#elif defined(__linux__)
#include <malloc.h>
#elif defined(__MACH__)
#include <malloc/malloc.h>
#endif

static size_t allocsize = 0;

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
#elif defined(__linux__)
	return malloc_usable_size(ptr);
#elif defined(__MACH__)
	return malloc_size(ptr);
#else
	return 0;
#endif
}

void *silly_malloc(size_t sz)
{
	void *ptr = MALLOC(sz);
	int real = xalloc_usable_size(ptr);
	atomic_add(&allocsize, real);
	return ptr;
}

void *silly_realloc(void *ptr, size_t sz)
{
	size_t realo = xalloc_usable_size(ptr);
	atomic_sub(&allocsize, realo);
	ptr = REALLOC(ptr, sz);
	size_t realn = xalloc_usable_size(ptr);
	atomic_add(&allocsize, realn);
	return ptr;
}

void silly_free(void *ptr)
{
	size_t real = xalloc_usable_size(ptr);
	atomic_sub(&allocsize, real);
	FREE(ptr);
}

#define BUILD(name, MAJOR, MINOR) (name "-" STR(MAJOR) "." STR(MINOR))

const char *silly_allocator()
{
#ifndef DISABLE_JEMALLOC
	return BUILD("jemalloc", JEMALLOC_VERSION_MAJOR,
		     JEMALLOC_VERSION_MINOR);
#else
	return "libc";
#endif
}

size_t silly_memused()
{
	return allocsize;
}

//Resident Set Size
size_t silly_memrss()
{
#if defined(__linux__)
	size_t rss;
	char *p, *end;
	int i, fd, err;
	char buf[4096];
	char filename[256];
	int page = sysconf(_SC_PAGESIZE);
	snprintf(filename, sizeof(filename), "/proc/%d/stat", getpid());
	fd = open(filename, O_RDONLY);
	if (fd == -1)
		return 0;
	err = read(fd, buf, 4095);
	close(fd);
	if (err <= 0)
		return 0;
	//RSS is the 24th field in /proc/$pid/stat
	i = 0;
	p = buf;
	end = &buf[err];
	while (p < end) {
		if (*p++ != ' ')
			continue;
		if ((++i) == 23)
			break;
	}
	if (i != 23)
		return 0;
	end = strchr(p, ' ');
	if (end == NULL)
		return 0;
	*end = '\0';
	rss = strtoll(p, NULL, 10) * page;
	return rss;
#else
	return allocsize;
#endif
}
