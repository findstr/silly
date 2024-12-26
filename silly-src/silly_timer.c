#include <assert.h>
#include <time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>

#ifdef __MACH__
#include <mach/clock.h>
#include <mach/mach.h>
#endif

#include "silly.h"
#include "atomic.h"
#include "spinlock.h"
#include "compiler.h"
#include "silly_conf.h"
#include "silly_log.h"
#include "silly_worker.h"
#include "silly_malloc.h"
#include "silly_timer.h"

#define SR_BITS (8) //root slot
#define SL_BITS (6) //level slot
#define SR_SIZE (1 << SR_BITS)
#define SL_SIZE (1 << SL_BITS)
#define SR_MASK (SR_SIZE - 1)
#define SL_MASK (SL_SIZE - 1)

#ifdef PAGE_SIZE
#undef PAGE_SIZE
#endif

struct page;

struct node {
	uint32_t expire;
	uint32_t version;
	uint32_t cookie; //page_id * PAGE_SIZE + page_offset
	uint32_t userdata;
	struct node *next;
	struct node **prev;
};

#define PAGE_SIZE (4096 / sizeof(struct node))

struct page {
	struct node buf[PAGE_SIZE];
};

struct pool {
	uint32_t cap;
	uint32_t count;
	struct node *free;
	struct page **buf;
};

struct slot_root {
	struct node *slot[SR_SIZE];
};

struct slot_level {
	struct node *slot[SL_SIZE];
};

struct silly_timer {
	spinlock_t lock;
	struct pool pool;
	uint32_t expire;
	uint64_t ticktime;
	uint64_t clocktime;
	uint64_t monotonic;
	struct slot_root root;
	struct slot_level level[4];
	uint32_t expired_count;
	uint32_t active_count;
};

static struct silly_timer *T;

static inline void lock(struct silly_timer *timer)
{
	spinlock_lock(&timer->lock);
}

static inline void unlock(struct silly_timer *timer)
{
	spinlock_unlock(&timer->lock);
}

static struct page *pool_newpage(struct pool *pool)
{
	uint32_t i;
	struct page *p;
	struct node *n;
	uint32_t page_id = pool->count++;
	assert(pool->free == NULL);
	if (pool->count >= pool->cap) {
		size_t newsz;
		pool->cap = 2 * pool->count;
		newsz = pool->cap * sizeof(pool->buf[0]);
		pool->buf = (struct page **)silly_realloc(pool->buf, newsz);
	}
	p = silly_malloc(sizeof(*p));
	pool->buf[page_id] = p;
	for (i = 0; i < PAGE_SIZE; i++) {
		n = &p->buf[i];
		n->prev = NULL;
		n->next = n + 1;
		n->version = 0;
		n->cookie = page_id * PAGE_SIZE + i;
	}
	n->next = NULL;
	return p;
}

static inline struct node *pool_locate(struct pool *pool, uint32_t cookie)
{
	uint32_t page_id = cookie / PAGE_SIZE;
	uint32_t page_offset = cookie % PAGE_SIZE;
	assert(page_id < pool->count);
	return &pool->buf[page_id]->buf[page_offset];
}

static inline void pool_init(struct pool *pool)
{
	struct page *p;
	pool->cap = 0;
	pool->count = 0;
	pool->buf = NULL;
	p = pool_newpage(pool);
	pool->free = &p->buf[0];
}

static void pool_free(struct pool *p)
{
	uint32_t i;
	for (i = 0; i < p->count; i++)
		silly_free(p->buf[i]);
	silly_free(p->buf);
}

static inline struct node *pool_newnode(struct silly_timer *t,
					struct pool *pool)
{
	struct node *n;
	if (pool->free == NULL) {
		struct page *p;
		unlock(t);
		p = pool_newpage(pool);
		lock(t);
		p->buf[PAGE_SIZE - 1].next = pool->free;
		pool->free = &p->buf[0];
	}
	n = pool->free;
	pool->free = n->next;
	n->version++;
	return n;
}

static inline void pool_freenode(struct pool *pool, struct node *n)
{
	n->next = pool->free;
	pool->free = n;
}

static inline void pool_freelist(struct pool *pool, struct node *head,
				 struct node **tail)
{
	*tail = pool->free;
	pool->free = head;
}

uint64_t silly_timer_now()
{
	return T->clocktime * TIMER_RESOLUTION;
}

time_t silly_timer_nowsec()
{
	int scale = 1000 / TIMER_RESOLUTION;
	return T->clocktime / scale;
}

uint64_t silly_timer_monotonic()
{
	return T->monotonic * TIMER_RESOLUTION;
}

time_t silly_timer_monotonicsec()
{
	int scale = 1000 / TIMER_RESOLUTION;
	return T->monotonic / scale;
}

uint32_t silly_timer_info(uint32_t *expired)
{
	if (expired != NULL)
		*expired = T->expired_count;
	return T->active_count;
}

static inline void linklist(struct node **list, struct node *n)
{
	if (*list != NULL) {
		(*list)->prev = &n->next;
	}
	n->next = *list;
	*list = n;
	n->prev = list;
}

static inline void unlinklist(struct node *n)
{
	*n->prev = n->next;
	if (n->next != NULL)
		n->next->prev = n->prev;
	n->prev = NULL;
	n->next = NULL;
}

static void add_node(struct silly_timer *timer, struct node *n)
{
	int i;
	int32_t idx = n->expire - timer->expire;
	if (idx < 0) { //timeout
		i = timer->expire & SR_MASK;
		linklist(&timer->root.slot[i], n);
	} else if (idx < SR_SIZE) {
		i = n->expire & SR_MASK;
		linklist(&timer->root.slot[i], n);
	} else {
		for (i = 0; i < 3; i++) {
			if (idx < 1 << ((i + 1) * SL_BITS + SR_BITS)) {
				idx = n->expire >> (i * SL_BITS + SR_BITS);
				idx &= SL_MASK;
				linklist(&timer->level[i].slot[idx], n);
				break;
			}
		}
		if (i == 3) { //the last level
			idx = n->expire >> (i * SL_BITS + SR_BITS);
			idx &= SL_MASK;
			linklist(&timer->level[i].slot[idx], n);
		}
	}
	return;
}

static inline uint64_t session_of(struct node *n)
{
	return (uint64_t)n->version << 32 | n->cookie;
}

static inline uint32_t version_of(uint64_t session)
{
	return session >> 32;
}

static inline uint32_t cookie_of(uint64_t session)
{
	return (uint32_t)session;
}

uint64_t silly_timer_timeout(uint32_t expire, uint32_t userdata)
{
	uint64_t session;
	struct node *n;
	atomic_add(&T->active_count, 1);
	atomic_add(&T->expired_count, 1);
	lock(T);
	n = pool_newnode(T, &T->pool);
	n->userdata = userdata;
	session = session_of(n);
	n->expire = expire / TIMER_RESOLUTION + T->ticktime;
	add_node(T, n);
	unlock(T);
	return session;
}

int silly_timer_cancel(uint64_t session, uint32_t *ud)
{
	struct node *n;
	uint32_t version = version_of(session);
	uint32_t cookie = cookie_of(session);
	atomic_sub(&T->active_count, 1);
	lock(T);
	n = pool_locate(&T->pool, cookie);
	if (n->version != version) {
		unlock(T);
		*ud = 0;
		silly_log_warn("[timer] cancel session late:%d %d", version,
			       n->version);
		return 0;
	}
	unlinklist(n);
	*ud = n->userdata;
	pool_freenode(&T->pool, n);
	unlock(T);
	return 1;
}

static void timeout(struct silly_timer *t, struct node *n)
{
	(void)t;
	struct silly_message_texpire *te;
	uint64_t session = session_of(n);
	atomic_sub(&T->active_count, 1);
	te = silly_malloc(sizeof(*te));
	te->type = SILLY_TEXPIRE;
	te->session = session;
	te->userdata = n->userdata;
	silly_worker_push(tocommon(te));
	return;
}

static uint64_t ticktime()
{
	uint64_t ms;
#ifdef __MACH__
	clock_serv_t cclock;
	mach_timespec_t mts;
	host_get_clock_service(mach_host_self(), SYSTEM_CLOCK, &cclock);
	clock_get_time(cclock, &mts);
	mach_port_deallocate(mach_task_self(), cclock);
	ms = (uint64_t)mts.tv_sec * 1000 / TIMER_RESOLUTION;
	ms += mts.tv_nsec / 1000000 / TIMER_RESOLUTION;
#else
	struct timespec tp;
	clock_gettime(CLOCK_MONOTONIC, &tp);
	ms = (uint64_t)tp.tv_sec * 1000 / TIMER_RESOLUTION;
	ms += tp.tv_nsec / 1000000 / TIMER_RESOLUTION;
#endif
	return ms;
}

static uint64_t clocktime()
{
	uint64_t ms;
	struct timeval t;
	gettimeofday(&t, NULL);
	ms = (uint64_t)t.tv_sec * 1000 / TIMER_RESOLUTION;
	ms += (uint64_t)t.tv_usec / 1000 / TIMER_RESOLUTION;
	return ms;
}

static void expire_timer(struct silly_timer *timer, struct node **tail)
{
	int idx = timer->expire & SR_MASK;
	while (timer->root.slot[idx]) {
		struct node *n = timer->root.slot[idx];
		timer->root.slot[idx] = NULL;
		unlock(timer);
		while (n) {
			struct node *tmp = n;
			n = n->next;
			assert((int32_t)(tmp->expire - timer->expire) <= 0);
			timeout(timer, tmp);
			*tail = tmp;
			tail = &tmp->next;
		}
		lock(timer);
	}
	return;
}

static int cascade_timer(struct silly_timer *timer, int level)
{
	struct node *n;
	int idx = timer->expire >> (level * SL_BITS + SR_BITS);
	idx &= SL_MASK;
	assert(level < 4);
	n = timer->level[level].slot[idx];
	timer->level[level].slot[idx] = NULL;
	while (n) {
		struct node *tmp = n;
		n = n->next;
		assert(tmp->expire >> (level * SL_BITS + SR_BITS) ==
		       timer->expire >> (level * SL_BITS + SR_BITS));
		add_node(timer, tmp);
	}
	return idx;
}

static void update_timer(struct silly_timer *timer, struct node **tail)
{
	uint32_t idx;
	lock(T);
	expire_timer(timer, tail);
	idx = ++timer->expire;
	idx &= SR_MASK;
	if (idx == 0) {
		int i;
		for (i = 0; i < 4; i++) {
			idx = cascade_timer(timer, i);
			if (idx != 0)
				break;
		}
	}
	expire_timer(timer, tail);
	unlock(T);
	return;
}

void silly_timer_update()
{
	int i;
	int delta;
	struct node *head;
	struct node **tail;
	uint64_t time = ticktime();
	if (T->ticktime == time)
		return;
	if (unlikely(T->ticktime > time)) {
		silly_log_error("[timer] time rewind change "
				"from %lld to %lld\n",
				T->ticktime, time);
	}
	delta = time - T->ticktime;
	assert(delta > 0);
	if (unlikely(delta > TIMER_DELAY_WARNING / TIMER_RESOLUTION)) {
		silly_log_warn("[timer] update delta is too big, "
			       "from:%lld ms to %lld ms\n",
			       T->ticktime * TIMER_RESOLUTION,
			       time * TIMER_RESOLUTION);
	}
	//uint64_t on x86 platform, can't assign as a atomic
	atomic_lock(&T->ticktime, time);
	atomic_add(&T->clocktime, delta);
	atomic_add(&T->monotonic, delta);
	head = NULL;
	tail = &head;
	for (i = 0; i < delta; i++)
		update_timer(T, tail);
	if (head != NULL) {
		lock(T);
		pool_freelist(&T->pool, head, tail);
		unlock(T);
	}
	assert((uint32_t)T->ticktime == T->expire);
	return;
}

void silly_timer_init()
{
	T = silly_malloc(sizeof(*T));
	memset(T, 0, sizeof(*T));
	T->clocktime = clocktime();
	T->ticktime = ticktime();
	T->expire = T->ticktime;
	T->monotonic = 0;
	spinlock_init(&T->lock);
	pool_init(&T->pool);
	return;
}

void silly_timer_exit()
{
	spinlock_destroy(&T->lock);
	pool_free(&T->pool);
	silly_free(T);
	return;
}
