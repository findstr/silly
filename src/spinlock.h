#ifndef _SPINLOCK_H
#define _SPINLOCK_H

#include "silly_conf.h"

#ifndef USE_SPINLOCK

#include <stdatomic.h>

#if defined(__x86_64__)
#include <immintrin.h> // For _mm_pause
#define atomic_pause_() _mm_pause()
#else
#define atomic_pause_() ((void)0)
#endif

typedef atomic_int spinlock_t;

static inline void spinlock_init(spinlock_t *lock)
{
	atomic_init(lock, 0);
}

static inline void spinlock_destroy(spinlock_t *lock)
{
	(void)lock;
}

static inline void spinlock_lock(spinlock_t *lock)
{
	for (;;) {
		if (!atomic_exchange_explicit(lock, 1, memory_order_acquire))
			return;
		while (atomic_load_explicit(lock, memory_order_relaxed))
			atomic_pause_();
	}
}

static inline void spinlock_unlock(spinlock_t *lock)
{
	atomic_store_explicit(lock, 0, memory_order_release);
}

#else
#include <pthread.h>

typedef pthread_spinlock_t spinlock_t;

static inline void spinlock_init(spinlock_t *lock)
{
	pthread_spin_init(lock, PTHREAD_PROCESS_PRIVATE);
}

static inline void spinlock_destroy(spinlock_t *lock)
{
	pthread_spin_destroy(lock);
}

static inline void spinlock_lock(spinlock_t *lock)
{
	pthread_spin_lock(lock);
}

static inline void spinlock_unlock(spinlock_t *lock)
{
	pthread_spin_unlock(lock);
}

#endif

#endif
