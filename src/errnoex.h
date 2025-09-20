#ifndef _ERRNO_EX_H
#define _ERRNO_EX_H

#include <errno.h>

#define EX_BASE (10000)

#define EX_ADDRINFO (EX_BASE + 0)
#define EX_NOSOCKET (EX_BASE + 1)
#define EX_CLOSING (EX_BASE + 2)
#define EX_CLOSED (EX_BASE + 3)
#define EX_EOF (EX_BASE + 4)

#endif