#ifndef _ERRNO_EX_H
#define _ERRNO_EX_H

#include <errno.h>

#define EXBASE (10000)

#define EXRESOLVE (EXBASE + 0)
#define EXNOSOCKET (EXBASE + 1)
#define EXCLOSING  (EXBASE + 2)
#define EXCLOSED   (EXBASE + 3)
#define EXEOF      (EXBASE + 4)
#define EXTLS      (EXBASE + 5)

#ifndef ETIMEDOUT
#define ETIMEDOUT  (EXBASE + 6)
#endif

#endif
