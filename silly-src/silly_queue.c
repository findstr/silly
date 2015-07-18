#include <stdio.h>

#include "silly_message.h"
#include "silly_malloc.h"

#include "silly_queue.h"

struct silly_queue {
        int lock;
        struct silly_message head;
        struct silly_message *tail;
};

static inline void
lock(struct silly_queue *q)
{
        while (__sync_lock_test_and_set(&q->lock, 1))
                ;

        return ;
}

static inline void
unlock(struct silly_queue *q)
{
        __sync_lock_release(&q->lock);

        return ;
}

struct silly_queue *silly_queue_create()
{
        struct silly_queue *q = (struct silly_queue *)silly_malloc(sizeof(*q));
        q->lock = 0;
        q->head.next = NULL;
        q->tail = &q->head;

        return q;
}

void silly_queue_free(struct silly_queue *q)
{
        free(q);

        return ;
}

int silly_queue_push(struct silly_queue *q, struct silly_message *msg)
{
        lock(q);
        q->tail->next = msg;
        msg->next = NULL;
        q->tail = msg;
        unlock(q);

        return 0;
}


struct silly_message *silly_queue_pop(struct silly_queue *q)
{
        struct silly_message *msg;

        if (q->head.next == NULL)
                return NULL;

        lock(q);
        //double check
        if (q->head.next == NULL) {
                unlock(q);
                return NULL;
        }

        msg = q->head.next;
        q->head.next = msg->next;
        if (q->tail == msg)
                q->tail = &q->head;

        unlock(q);

        return msg;
}


