#include <malloc.h>
#include "silly_malloc.h"

static size_t allocsize = 0;

void *
silly_malloc(size_t sz)
{
        void *ptr = malloc(sz);
        int real = malloc_usable_size(ptr);
        __sync_fetch_and_add(&allocsize, real);
        return ptr;
}

void *silly_realloc(void *ptr, size_t sz)
{
        size_t realo = malloc_usable_size(ptr);
        ptr = realloc(ptr, sz);
        size_t realn = malloc_usable_size(ptr);
        if (realo > realn)      //shrink
                __sync_fetch_and_sub(&allocsize, realo - realn);
        else
                __sync_fetch_and_add(&allocsize, realn - realo);
        return ptr;
}

void 
silly_free(void *ptr)
{
        size_t real = malloc_usable_size(ptr);
        __sync_fetch_and_sub(&allocsize, real);
        free(ptr);
}

size_t
silly_memstatus()
{
        return allocsize;
}

