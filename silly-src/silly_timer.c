#include <time.h>
#include <stdio.h>
#include <stdlib.h>

#ifdef __macosx__
#include <mach/clock.h>
#include <mach/mach.h>
#endif

#include "silly_message.h"
#include "silly_malloc.h"
#include "silly_server.h"
#include "silly_timer.h"

struct timer_node {
        int                     expire;
        int                     workid;
        uintptr_t               sig;
        struct timer_node       *next;
};

struct timer {
        int     lock;       
        struct timer_node *list;
};

static struct timer *TIMER;

int timer_init()
{
        TIMER = (struct timer *)malloc(sizeof(*TIMER));
        TIMER->list = NULL;
        TIMER->lock = 0;

        return 0;
}

void timer_exit()
{
        free(TIMER->list);
        free(TIMER);
}

static int
_getms()
{
        int ms;
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

static struct timer_node *
_new_node(int time, int workid, uintptr_t sig)
{
        struct timer_node *node = (struct timer_node *)malloc(sizeof(*node));
        node->workid = workid;
        node->sig = sig;
        node->expire = _getms() + time;

        return node;
}

//ms
int timer_add(int time, int workid, uintptr_t sig)
{
        struct timer_node *n = _new_node(time, workid, sig);
        if (n == NULL) {
                fprintf(stderr, "_new_node fail\n");
                return -1;
        }
 
        while (__sync_lock_test_and_set(&TIMER->lock, 1))
                ;

        n->next = TIMER->list;
        TIMER->list = n;
        
        __sync_lock_release(&TIMER->lock);

        return 0;
}

static void
_push_timer_event(struct timer *t, int workid, uintptr_t sig)
{
        struct silly_message *s = (struct silly_message *)silly_malloc(sizeof(*s));
        s->type = SILLY_MESSAGE_TIMER;
        s->msg.timer = silly_malloc(sizeof(struct silly_message_timer));
        s->msg.timer->sig = sig;
        silly_server_push(workid, s);

        return ;
}

int timer_dispatch()
{
        int curr = _getms();
        struct timer_node *t;
        struct timer_node *last;

        while(__sync_lock_test_and_set(&TIMER->lock, 1))
                ;

        t = TIMER->list;
        last = TIMER->list;
        while (t) {
                if (t->expire <= curr) {
                        struct timer_node *tmp;
                        _push_timer_event(TIMER, t->workid, t->sig);
                        if (last == TIMER->list)
                                TIMER->list = t->next;
                        else
                                last->next = t->next;
                        tmp = t;
                        t = t->next;
                        free(tmp);
                } else {
                        last = t;
                        t = t->next;
                }
        }

        __sync_lock_release(&TIMER->lock);

        return 0;
}


