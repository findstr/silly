#include <assert.h>
#include <time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <stdatomic.h>

#ifdef __MACH__
#include <mach/clock.h>
#include <mach/mach.h>
#endif

#include "silly.h"
#include "spinlock.h"
#include "message.h"
#include "silly_conf.h"
#include "flipbuf.h"
#include "worker.h"
#include "timer.h"
#include "mem.h"
#include "log.h"

enum OP {
	OP_AFTER = 0,
	OP_CANCEL = 1,
	OP_EXIT = 2,
};

enum NODE_STATE {
	NODE_ADDING = 0,
	NODE_TICKING = 1,
	NODE_CANCLED = 2,
	NODE_FREED = 3,
};

#define SR_BITS (8) //root slot
#define SL_BITS (6) //level slot
#define SR_SIZE (1 << SR_BITS)
#define SL_SIZE (1 << SL_BITS)
#define SR_MASK (SR_SIZE - 1)
#define SL_MASK (SL_SIZE - 1)

#ifdef PAGE_SIZE
#undef PAGE_SIZE
#endif

#define atomic_load_relax(a) atomic_load_explicit(&(a), memory_order_relaxed)

#define atomic_store_relax(a, v) \
	atomic_store_explicit(&(a), (v), memory_order_relaxed)

#define atomic_sub_relax(a, v) \
	atomic_fetch_sub_explicit(&(a), (v), memory_order_relaxed)

#define atomic_add_relax(a, v) \
	atomic_fetch_add_explicit(&(a), (v), memory_order_relaxed)

struct page;

struct node {
	atomic_uint_least32_t version;
	atomic_uint_least8_t state;
	uint32_t cookie;
	uint32_t expire;
	struct node *next;
	struct node **prev;
};

struct cmdafter {
	struct node *n;
};

struct cmdcancel {
	struct node *n;
	uint32_t version;
};

struct cmdpkt {
	enum OP op;
	union {
		struct cmdafter after;
		struct cmdcancel cancel;
	};
};

#define PAGE_SIZE (4096 / sizeof(struct node))

struct page {
	struct node buf[PAGE_SIZE];
};

struct pool {
	spinlock_t lock;
	uint32_t cap;
	uint32_t count;
	struct node *free;
	struct node **tail;
	struct page **buf;
};

struct slot_root {
	struct node *slot[SR_SIZE];
};

struct slot_level {
	struct node *slot[SL_SIZE];
};

struct timer {
	struct pool pool;
	uint64_t startwall;
	uint32_t jiffies;
	atomic_uint_least64_t ticktime;
	atomic_uint_least64_t monotonic;
	struct slot_root root;
	struct slot_level level[4];
	struct silly_timerstat stat;
	struct flipbuf cmdbuf;
};

struct message_expire { //timer expire
	struct silly_message hdr;
	uint64_t session;
};

static struct timer *T;

static struct page *pool_newpage(struct pool *pool)
{
	uint32_t i;
	struct page *p;
	struct node *n;
	uint32_t page_id = pool->count++;
	if (pool->count >= pool->cap) {
		size_t newsz;
		pool->cap = 2 * pool->count;
		newsz = pool->cap * sizeof(pool->buf[0]);
		pool->buf = (struct page **)mem_realloc(pool->buf, newsz);
	}
	p = mem_alloc(sizeof(*p));
	memset(p, 0, sizeof(*p));
	pool->buf[page_id] = p;
	for (i = 0; i < PAGE_SIZE; i++) {
		n = &p->buf[i];
		atomic_store_relax(n->state, NODE_FREED);
		n->next = n + 1;
		n->cookie = page_id * PAGE_SIZE + i;
	}
	n->next = NULL;
	return p;
}

static inline void pool_init(struct pool *pool)
{
	struct page *p;
	pool->cap = 0;
	pool->count = 0;
	pool->buf = NULL;
	p = pool_newpage(pool);
	pool->free = &p->buf[0];
	pool->tail = &p->buf[PAGE_SIZE - 1].next;
	spinlock_init(&pool->lock);
}

static void pool_free(struct pool *p)
{
	uint32_t i;
	for (i = 0; i < p->count; i++)
		mem_free(p->buf[i]);
	mem_free(p->buf);
	spinlock_destroy(&p->lock);
}

static inline struct node *pool_locate(struct pool *pool, uint32_t cookie)
{
	struct node *n;
	uint32_t page_id = cookie / PAGE_SIZE;
	uint32_t page_offset = cookie % PAGE_SIZE;
	assert(page_id < pool->count);
	n = &pool->buf[page_id]->buf[page_offset];
	return n;
}

static inline void pool_freelist(struct pool *pool, struct node *head,
				 struct node **tail)
{
	spinlock_lock(&pool->lock);
	*pool->tail = head;
	pool->tail = tail;
	spinlock_unlock(&pool->lock);
}

static inline struct node *pool_newnode(struct pool *pool)
{
	struct node *n;
	spinlock_lock(&pool->lock);
	if (pool->free == NULL) {
		struct page *p;
		struct node *head, **tail;
		spinlock_unlock(&pool->lock);
		p = pool_newpage(pool);
		head = &p->buf[0];
		tail = &p->buf[PAGE_SIZE - 1].next;
		spinlock_lock(&pool->lock);
		*pool->tail = head;
		pool->tail = tail;
	}
	n = pool->free;
	pool->free = n->next;
	if (pool->free == NULL) {
		pool->tail = &pool->free;
	}
	spinlock_unlock(&pool->lock);
	return n;
}

uint64_t timer_now()
{
	uint64_t start = T->startwall;
	uint64_t mono = atomic_load_relax(T->monotonic);
	return start + mono;
}

uint64_t timer_monotonic()
{
	return atomic_load_relax(T->monotonic);
}

void timer_stat(struct silly_timerstat *stat)
{
	stat->pending = atomic_load_relax(T->stat.pending);
	stat->scheduled = atomic_load_relax(T->stat.scheduled);
	stat->fired = atomic_load_relax(T->stat.fired);
	stat->canceled = atomic_load_relax(T->stat.canceled);
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

static void add_node(struct timer *timer, struct node *n)
{
	int i;
	int32_t idx = n->expire - timer->jiffies;
	if (idx < 0) { //timeout
		i = timer->jiffies & SR_MASK;
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
	return (uint64_t)atomic_load_relax(n->version) << 32 | n->cookie;
}

static inline uint32_t version_of(uint64_t session)
{
	return session >> 32;
}

static inline uint32_t cookie_of(uint64_t session)
{
	return (uint32_t)session;
}

uint64_t timer_after(uint32_t timeout)
{
	struct node *n;
	uint64_t session;
	uint64_t deadline;
	struct cmdpkt cmd;
	atomic_add_relax(T->stat.scheduled, 1);
	atomic_add_relax(T->stat.pending, 1);
	n = pool_newnode(&T->pool);
	assert(atomic_load_relax(n->state) == NODE_FREED);
	atomic_store_relax(n->state, NODE_ADDING);
	deadline = atomic_load_relax(T->ticktime) + timeout + TIMER_RESOLUTION - 1;
	n->expire = deadline / TIMER_RESOLUTION;
	session = session_of(n);
	cmd.op = OP_AFTER;
	cmd.after.n = n;
	flipbuf_write(&T->cmdbuf, (const uint8_t *)&cmd, sizeof(cmd));
	return session;
}

int timer_cancel(uint64_t session)
{
	struct node *n;
	uint32_t nver;
	struct cmdpkt cmd;
	uint32_t version = version_of(session);
	uint32_t cookie = cookie_of(session);
	n = pool_locate(&T->pool, cookie);
	// first load version
	nver = atomic_load_explicit(&n->version, memory_order_acquire);
	if (nver != version) {
		log_warn("[timer] cancel session invalid:%d %d\n",
			version, cookie);
		return 0;
	}
	cmd.op = OP_CANCEL;
	cmd.cancel.n = n;
	cmd.cancel.version = version;
	flipbuf_write(&T->cmdbuf, (const uint8_t *)&cmd, sizeof(cmd));
	return 1;
}

static int expire_unpack(lua_State *L, struct silly_message *msg)
{
	struct message_expire *ms =
		container_of(msg, struct message_expire, hdr);
	lua_pushinteger(L, ms->session);
	return 1;
}

static void timeout(struct timer *t, struct node *n)
{
	(void)t;
	struct message_expire *te;
	uint64_t session = session_of(n);
	atomic_sub_relax(T->stat.pending, 1);
	atomic_add_relax(T->stat.fired, 1);
	te = mem_alloc(sizeof(*te));
	te->hdr.type = MESSAGE_TIMER_EXPIRE;
	te->hdr.unpack = expire_unpack;
	te->hdr.free = mem_free;
	te->session = session;
	worker_push(&te->hdr);
	return;
}

static uint64_t ticktime()
{
	uint64_t total_ms;
#ifdef __MACH__
	clock_serv_t cclock;
	mach_timespec_t mts;
	host_get_clock_service(mach_host_self(), SYSTEM_CLOCK, &cclock);
	clock_get_time(cclock, &mts);
	mach_port_deallocate(mach_task_self(), cclock);
	total_ms = (uint64_t)mts.tv_sec * 1000 + mts.tv_nsec / 1000000;
#else
	struct timespec tp;
	clock_gettime(CLOCK_MONOTONIC, &tp);
	total_ms = (uint64_t)tp.tv_sec * 1000 + tp.tv_nsec / 1000000;
#endif
	return total_ms;
}

static uint64_t walltime()
{
	struct timeval t;
	uint64_t total_ms;
	gettimeofday(&t, NULL);
	total_ms = (uint64_t)t.tv_sec * 1000 + (uint64_t)t.tv_usec / 1000;
	return total_ms;
}

static inline void node_free(struct node ***tail, struct node *n)
{
	**tail = n;
	*tail = &n->next;
	atomic_add_relax(n->version, 1);
	atomic_store_relax(n->state, NODE_FREED);
}

static inline void expire_timer(struct timer *timer, struct node ***tail)
{
	int idx = timer->jiffies & SR_MASK;
	while (timer->root.slot[idx]) {
		struct node *n = timer->root.slot[idx];
		timer->root.slot[idx] = NULL;
		while (n) {
			struct node *tmp = n;
			n = n->next;
			assert((int32_t)(tmp->expire - timer->jiffies) <= 0);
			timeout(timer, tmp);
			node_free(tail, tmp);
		}
	}
}

static int cascade_timer(struct timer *timer, int level)
{
	struct node *n;
	int idx = timer->jiffies >> (level * SL_BITS + SR_BITS);
	idx &= SL_MASK;
	assert(level < 4);
	n = timer->level[level].slot[idx];
	timer->level[level].slot[idx] = NULL;
	while (n) {
		struct node *tmp = n;
		n = n->next;
		assert(tmp->expire >> (level * SL_BITS + SR_BITS) ==
		       timer->jiffies >> (level * SL_BITS + SR_BITS));
		add_node(timer, tmp);
	}
	return idx;
}

static void update_timer(struct timer *timer, struct node ***tail)
{
	uint32_t idx;
	expire_timer(timer, tail);
	idx = ++timer->jiffies;
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
	return;
}

static inline int process_cancel(struct cmdcancel *cmd, struct node ***tail)
{
	int state;
	struct node *n = cmd->n;
	if (atomic_load_relax(n->version) != cmd->version)
		return 0;
	state = atomic_load_relax(n->state);
	assert(state == NODE_TICKING);
	unlinklist(n);
	node_free(tail, n);
	return 1;
}

static inline void process_after(struct cmdafter *cmd)
{
	struct node *n = cmd->n;
	int state = atomic_load_relax(n->state);
	assert(state == NODE_ADDING);
	atomic_store_relax(n->state, NODE_TICKING);
	add_node(T, n);
}

static inline int process_cmd(struct node ***tail)
{
	int cancel_count = 0;
	struct cmdpkt *ptr, *end;
	struct array *arr = flipbuf_flip(&T->cmdbuf);
	assert(arr->size % sizeof(struct cmdpkt) == 0);
	ptr = (struct cmdpkt *)arr->buf;
	end = (struct cmdpkt *)(arr->buf + arr->size);
	for (; ptr < end; ptr++) {
		switch (ptr->op) {
		case OP_AFTER:
			process_after(&ptr->after);
			break;
		case OP_CANCEL:
			cancel_count += process_cancel(&ptr->cancel, tail);
			break;
		case OP_EXIT:
			return -1;
			break;
		}
	}
	atomic_sub_relax(T->stat.pending, cancel_count);
	atomic_add_relax(T->stat.canceled, cancel_count);
	return 0;
}

int timer_update()
{
	struct node *head;
	struct node **tail;
	int i, delta, ticks, tickstep;
	uint64_t time = ticktime();
	uint64_t lasttick = atomic_load_relax(T->ticktime);
	if (time < lasttick + TIMER_RESOLUTION) {
		return (int)(lasttick + TIMER_RESOLUTION - time);
	}
	if (unlikely(lasttick > time)) {
		log_error("[timer] time rewind change "
			  "from %lld to %lld\n",
			  lasttick, time);
	}
	delta = time - lasttick;
	assert(delta > 0);
	if (unlikely(delta > TIME_DELAY_WARNING)) {
		log_warn("[timer] update delta is too big, "
			 "from:%lld ms to %lld ms\n",
			 lasttick, time);
	}
	ticks = delta / TIMER_RESOLUTION;
	tickstep = ticks * TIMER_RESOLUTION;
	atomic_add_relax(T->ticktime, tickstep);
	atomic_add_relax(T->monotonic, tickstep);
	head = NULL;
	tail = &head;
	if (process_cmd(&tail) < 0) {
		return -1;
	}
	for (i = 0; i < ticks; i++)
		update_timer(T, &tail);
	*tail = NULL;
	if (head != NULL) {
		pool_freelist(&T->pool, head, tail);
	}
	assert((uint32_t)atomic_load_relax(T->ticktime) == T->jiffies * TIMER_RESOLUTION);
	return TIMER_RESOLUTION - (delta % TIMER_RESOLUTION);
}

void timer_stop()
{
	struct cmdpkt cmd;
	cmd.op = OP_EXIT;
	flipbuf_write(&T->cmdbuf, (const uint8_t *)&cmd, sizeof(cmd));
	return;
}

void timer_init()
{
	uint64_t tt;
	T = mem_alloc(sizeof(*T));
	memset(T, 0, sizeof(*T));
	tt = ticktime();
	T->startwall = walltime();
	T->jiffies = tt / TIMER_RESOLUTION;
	atomic_init(&T->ticktime, tt / TIMER_RESOLUTION * TIMER_RESOLUTION);
	atomic_init(&T->monotonic, 0);
	atomic_init(&T->stat.pending, 0);
	atomic_init(&T->stat.scheduled, 0);
	atomic_init(&T->stat.fired, 0);
	atomic_init(&T->stat.canceled, 0);
	pool_init(&T->pool);
	flipbuf_init(&T->cmdbuf);
	return;
}

void timer_exit()
{
	pool_free(&T->pool);
	flipbuf_destroy(&T->cmdbuf);
	mem_free(T);
	return;
}