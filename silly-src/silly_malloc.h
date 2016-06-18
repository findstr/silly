#ifndef _SILLY_MALLOC_H
#define _SILLY_MALLOC_H

#include <stdlib.h>

void *silly_malloc(size_t sz);
void *silly_realloc(void *ptr, size_t sz);
void silly_free(void *ptr);
size_t silly_memstatus();

#endif

