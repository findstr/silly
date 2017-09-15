#ifndef	_COMPILER_H
#define	_COMPILER_H

#if defined __GNUC__

#define likely(x) __builtin_expect(!!(x), 1)
#define unlikely(x) __builtin_expect(!!(x), 0)

#else

#define likely(x)	(x)
#define unlikely(x)	(x)

#endif

#endif

