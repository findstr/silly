#ifndef	_SPINLOCK_H
#define	_SPINLOCK_H

#ifndef USE_SPINLOCK
#include "atomic.h"
typedef int spinlock_t;
static inline void
spinlock_init(spinlock_t *lock)
{
	*lock = 0;
}

static inline void
spinlock_destroy(spinlock_t *lock)
{
	(void)lock;
}

static inline void
spinlock_lock(spinlock_t *lock)
{
	while (atomic_lock(lock, 1))
		;
}

static inline void
spinlock_unlock(spinlock_t *lock)
{
	atomic_release(lock);
}

#else
#include <pthread.h>

typedef pthread_spinlock_t spinlock_t;

static inline void
spinlock_init(spinlock_t *lock)
{
	pthread_spin_init(lock, PTHREAD_PROCESS_PRIVATE);
}

static inline void
spinlock_destroy(spinlock_t *lock)
{
	pthread_spin_destroy(lock);
}

static inline void
spinlock_lock(spinlock_t *lock)
{
	pthread_spin_lock(lock);
}

static inline void
spinlock_unlock(spinlock_t *lock)
{
	pthread_spin_unlock(lock);
}

#endif

#endif

