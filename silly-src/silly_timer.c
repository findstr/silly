#include <assert.h>
#include <time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>

#ifdef __macosx__
#include <mach/clock.h>
#include <mach/mach.h>
#endif

#include "silly.h"
#include "silly_worker.h"
#include "silly_malloc.h"
#include "silly_timer.h"

#define SR_BITS         (8)     //root slot
#define SL_BITS         (6)     //level slot
#define SR_SIZE         (1 << SR_BITS)
#define SL_SIZE         (1 << SL_BITS)
#define SR_MASK         (SR_SIZE - 1)
#define SL_MASK         (SL_SIZE - 1)

struct node {
        uint32_t        expire;
        uint32_t        session;
        struct node     *next;
};

struct slot_root {
        struct node *slot[SR_SIZE];
};

struct slot_level {
        struct node *slot[SL_SIZE];
};

struct silly_timer {
        int                     lock;
        uint64_t                time;
        uint32_t                expire;
        struct slot_root        root;
        struct slot_level       level[4];
};

static struct silly_timer *T;

static inline struct node *
newnode()
{
        struct node *n = silly_malloc(sizeof(*n));
        uint32_t session = silly_worker_genid();
        n->session = session;
        return n;
}

static inline void
freenode(struct node *n)
{
        silly_free(n);
        return ;
}

static inline void
lock(struct silly_timer *timer)
{
        while (__sync_lock_test_and_set(&timer->lock, 1))
                ;

}

static inline void
unlock(struct silly_timer *timer)
{
        __sync_lock_release(&timer->lock);
}

uint64_t
silly_timer_now()
{
        return T->time;
}

static inline void
linklist(struct node **list, struct node *n)
{
        n->next = *list;
        *list = n;
}

static void
add_node(struct silly_timer *timer, struct node *n)
{
        int     i;
        int32_t idx = n->expire - timer->expire;
        if (idx < 0) {  //timeout
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
                if (i == 3) {//the last level
                        idx = n->expire >> (i * SL_BITS + SR_BITS);
                        idx &= SL_MASK;
                        linklist(&timer->level[i].slot[idx], n);
                }
        }
        return ;
}

uint32_t
silly_timer_timeout(uint32_t expire)
{
        struct node *n = newnode();
        if (n == NULL) {
                fprintf(stderr, "silly timer alloc node failed\n");
                return -1;
        }
        lock(T);
        n->expire = expire + T->time;
        assert((int32_t)(n->expire - T->expire) >= 0);
        add_node(T, n);
        unlock(T);
        return n->session;
}

static void
timeout(struct silly_timer *t, uint32_t session)
{
        struct silly_message_texpire *te;
        te = silly_malloc(sizeof(*te));
        te->type = SILLY_TEXPIRE;
        te->session = session;
        silly_worker_push(tocommon(te));
        return ;
}

static uint64_t
getms()
{
        uint64_t ms;
#ifdef __macosx__
        clock_serv_t cclock;
        mach_timespec_t mts;
        host_get_clock_service(mach_host_self(), CALENDAR_CLOCK, &cclock);
        clock_get_time(cclock, &mts);
        mach_port_deallocate(mach_task_self(), cclock);
        ms = (uint64_t)mts.tv_sec * 1000;
        ms += mts.tv_nsec / 1000000;
#else
        struct timespec tp;
        clock_gettime(CLOCK_MONOTONIC, &tp);
        ms = (uint64_t)tp.tv_sec * 1000;
        ms += tp.tv_nsec / 1000000;
#endif
        return ms;
}

static void
expire_timer(struct silly_timer *timer)
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
                        timeout(timer, tmp->session);
                        freenode(tmp);   
                }
                lock(timer);
        }
        return ;
}

static int
cascade_timer(struct silly_timer *timer, int level)
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

static void
update_timer(struct silly_timer *timer)
{
        uint32_t idx;
        lock(T);
        expire_timer(timer);
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
        expire_timer(timer);
        unlock(T);
        return ;
}

void
silly_timer_update()
{
        int     i;
        int     delta;
        uint64_t time = getms();
        if (T->time == time)
                return;
        if (T->time > time) {
                const char *fmt =
                "[silly.timer] time rewind change from %lld to %lld\n";
                fprintf(stderr, fmt, T->time, time);
        }
        delta = time - T->time;
        assert(delta > 0);
        //uint64_t on x86 platform, can't assign as a automatic
        __sync_lock_test_and_set(&T->time, time);
        for (i = 0; i < delta; i++)
                update_timer(T);
        assert((uint32_t)T->time == T->expire);
        return ;
}

void
silly_timer_init()
{
        T = silly_malloc(sizeof(*T));
        memset(T, 0, sizeof(*T));
        T->time = getms();
        T->expire = T->time;
        return ;
}

static inline void
freelist(struct node *n)
{
        while (n) {
                struct node *tmp = n;
                n = n->next;
                freenode(tmp);
        }
        return ;
}

void
silly_timer_exit()
{
        int i, j;
        for (i = 0; i < SR_SIZE; i++)
                freelist(T->root.slot[i]);
        for (i = 0; i < 4; i++) {
                for (j = 0; j < SL_SIZE; j++)
                        freelist(T->level[i].slot[j]);
        }
        silly_free(T);
        return ;
}

