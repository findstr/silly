#ifndef _SILLY_MALLOC_H
#define _SILLY_MALLOC_H

#include <stdlib.h>

#define silly_malloc(a) malloc(a)
#define silly_realloc(a, size) realloc(a, size)
#define silly_free(a) free(a)

#endif

