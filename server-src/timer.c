#include <time.h>
#include <stdlib.h>

#include "event.h"
#include "timer.h"

struct timer_node {
        int     expire;
        void    (*cb)(void *ud);
        void    *ud;
        struct timer_node *next;
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
        struct timespec tp;
        clock_gettime(CLOCK_MONOTONIC, &tp);
        ms = tp.tv_sec * 1000;
        ms += tp.tv_nsec / 1000000;

        return ms;
}

static struct timer_node *
_new_node(int time, void (*cb)(void *ud), void *ud)
{
        struct timer_node *node = (struct timer_node *)malloc(sizeof(*node));
        node->cb = cb;
        node->ud = ud;
        node->expire = _getms() + time;

        return node;
}

//ms
int timer_add(int time, void (*cb)(void *ud), void *ud)
{
        struct timer_node *n = _new_node(time, cb, ud);
        if (n == NULL)
                return -1;
 

        while (__sync_lock_test_and_set(&TIMER->lock, 1))
                ;

        n->next = TIMER->list;
        TIMER->list = n;
        
        __sync_lock_release(&TIMER->lock);

        return 0;
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
                if (t->expire >= curr) {
                        struct timer_node *tmp;
                        struct event_handler e;
                        e.ud = t->ud;
                        e.cb = t->cb;
                        event_add_handler(&e);
                        last->next = t->next;
                        tmp = t;
                        t = t->next;
                        free(tmp);
                }
                
                if (t)
                        t = t->next;
        }

        __sync_lock_release(&TIMER->lock);

        return 0;
}


