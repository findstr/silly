#include <assert.h>
#include <time.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/time.h>

#ifdef __macosx__
#include <mach/clock.h>
#include <mach/mach.h>
#endif

#include "silly.h"
#include "silly_worker.h"
#include "silly_malloc.h"
#include "silly_timer.h"

#define CHUNKSIZE        (32)

struct node {
        int             expire;
        uint64_t        session;
        struct node     *next;
};

struct chunk {
        struct chunk *next;
        //append CHUNKSIZE nodes
};

struct silly_timer {
        int     lock;       
        struct node list;
        struct node *nodefree;
        struct chunk *nodepool;
};

static struct silly_timer *TIMER;

static uint32_t
getms()
{
        uint32_t ms;
#ifdef __macosx__
        clock_serv_t cclock;
        mach_timespec_t mts;
        host_get_clock_service(mach_host_self(), CALENDAR_CLOCK, &cclock);
        clock_get_time(cclock, &mts);
        mach_port_deallocate(mach_task_self(), cclock);
        ms = mts.tv_sec * 1000;
        ms += mts.tv_nsec / 1000000;
#else
        struct timespec tp;
        clock_gettime(CLOCK_MONOTONIC, &tp);
        ms = tp.tv_sec * 1000;
        ms += tp.tv_nsec / 1000000;
#endif
        return ms;
}

static void
newchunk(struct silly_timer *timer)
{
        int i;
        size_t sz = sizeof(struct chunk) + sizeof(struct node) * CHUNKSIZE;
        struct chunk *ck = silly_malloc(sz);
        struct node *nh = (struct node *)(ck + 1);
        struct node *nt = nh;
        for (i = 0; i < CHUNKSIZE - 1; i++) {
                nh[i].next = (++nt);
        }
        nt->next = timer->nodefree;
        timer->nodefree = nh;
        ck->next = timer->nodepool;
        timer->nodepool = ck->next;
        return ;
}

static struct node *
newnode(struct silly_timer *timer, uint32_t expire)
{
        struct node *n = timer->nodefree;
        if (n == NULL)
                newchunk(timer);
        n = timer->nodefree;
        assert(n);
        timer->nodefree = n->next;
        uint32_t session = silly_worker_genid();
        n->session = session;
        n->expire = getms() + expire;
        return n;
}

static void
freenode(struct silly_timer *timer, struct node *n)
{
        n->next = timer->nodefree;
        timer->nodefree = n;
        return ;
}

uint32_t
silly_timer_now()
{
        uint32_t ms;
        struct timeval tv;
        gettimeofday(&tv, NULL);
        ms = tv.tv_sec * 1000;
        ms += tv.tv_usec / 1000;
        return ms;
}

uint32_t
silly_timer_timeout(uint32_t expire)
{
        struct node *n = newnode(TIMER, expire);
        if (n == NULL) {
                fprintf(stderr, "silly timer alloc node failed\n");
                return -1;
        }
        while (__sync_lock_test_and_set(&TIMER->lock, 1))
                ;
        n->next = TIMER->list.next;
        TIMER->list.next = n;
        __sync_lock_release(&TIMER->lock);
        return n->session;
}

static void
timeout(struct silly_timer *t, uint64_t session)
{
        struct silly_message_texpire *te;
        te = silly_malloc(sizeof(*te));
        te->type = SILLY_TEXPIRE;
        te->session = session;
        silly_worker_push(tocommon(te));
        return ;
}

void
silly_timer_dispatch()
{
        uint32_t curr = getms();
        struct node *t;
        struct node *last;
        while(__sync_lock_test_and_set(&TIMER->lock, 1))
                ;
        t = TIMER->list.next;
        last = &TIMER->list;
        while (t) {
                if (t->expire <= curr) {
                        struct node *tmp;
                        timeout(TIMER, t->session);
                        last->next = t->next;
                        tmp = t;
                        t = t->next;
                        freenode(TIMER, tmp);
                } else {
                        t = t->next;
                        last = last->next;
                }
                        
        }
        __sync_lock_release(&TIMER->lock);

        return ;
}

void
silly_timer_init()
{
        TIMER = silly_malloc(sizeof(*TIMER));
        TIMER->list.next = NULL;
        TIMER->lock = 0;
        TIMER->nodefree = NULL;
        TIMER->nodepool = NULL;
        return ;
}

void
silly_timer_exit()
{
        struct chunk *ck = TIMER->nodepool;
        while (ck) {
                struct chunk *tmp;
                tmp = ck;
                ck = ck->next;
                silly_free(tmp);
        }
        silly_free(TIMER);
        return ;
}

