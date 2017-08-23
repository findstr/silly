#ifndef	_ATOMIC_H
#define	_ATOMIC_H

#include <stdint.h>

#define	atomic_add(a, b)	__sync_fetch_and_add((a), (b))
#define atomic_add_return(a, b) __sync_add_and_fetch((a), (b))

#define	atomic_sub(a, b)	__sync_fetch_and_sub((a), (b))
#define	atomic_sub_return(a, b) __sync_sub_and_fetch((a), (b))

#define	atomic_and(a, b)	__sync_fetch_and_and((a), (b))
#define	atomic_and_return(a, b) __sync_and_and_fetch((a), (b))

#define	atomic_xor(a, b)	__sync_fetch_and_xor((a), (b))
#define	atomic_xor_return(a, b) __sync_xor_and_fetch((a), (b))

#define	atomic_lock(a, b)	__sync_lock_test_and_set((a), (b))
#define	atomic_release(a)	__sync_lock_release((a))

#define	atomic_swap(a, o, n)	__sync_bool_compare_and_swap((a), (o), (n))

#define	atomic_barrier()	__sync_synchronize()

#endif

