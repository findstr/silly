#ifndef _COMPILER_H
#define _COMPILER_H

#if defined(_MSC_VER)
#define THREAD_LOCAL __declspec(thread)
#elif defined(__GNUC__) || defined(__clang__)
#define THREAD_LOCAL __thread
#elif defined(__STDC_VERSION__) && (__STDC_VERSION__ >= 201112L) && \
	(!defined(__STDC_NO_THREADS__))
#define THREAD_LOCAL _Thread_local
#else
#warning "Thread-local storage not supported on this compiler."
#define THREAD_LOCAL
#endif

#if defined(__GNUC__)
#define likely(x) __builtin_expect(!!(x), 1)
#define unlikely(x) __builtin_expect(!!(x), 0)
#else
#define likely(x) (x)
#define unlikely(x) (x)
#endif

#endif
