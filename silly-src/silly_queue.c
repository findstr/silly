#include <stdio.h>
#include "atomic.h"
#include "spinlock.h"
#include "silly.h"
#include "silly_malloc.h"

#include "silly_queue.h"

struct silly_queue {
	size_t size;
	struct silly_message **tail;
	struct silly_message *head;
	spinlock_t lock;
};

static inline void
lock(struct silly_queue *q)
{
	spinlock_lock(&q->lock);
}

static inline void
unlock(struct silly_queue *q)
{
	spinlock_unlock(&q->lock);
	return ;
}

struct silly_queue *
silly_queue_create()
{
	struct silly_queue *q = (struct silly_queue *)silly_malloc(sizeof(*q));
	q->size = 0;
	q->head = NULL;
	q->tail = &q->head;
	spinlock_init(&q->lock);
	return q;
}

void
silly_queue_free(struct silly_queue *q)
{
	struct silly_message *next, *tmp;
	lock(q);
	next = q->head;
	while (next) {
		tmp = next;
		next = next->next;
		silly_message_free(tmp);
	}
	unlock(q);
	spinlock_destroy(&q->lock);
	silly_free(q);
	return ;
}

int
silly_queue_push(struct silly_queue *q, struct silly_message *msg)
{
	msg->next = NULL;
	lock(q);
	*q->tail = msg;
	q->tail = &msg->next;
	unlock(q);
	return atomic_add_return(&q->size, 1);
}


struct silly_message *
silly_queue_pop(struct silly_queue *q)
{
	struct silly_message *msg;
	if (q->head == NULL)
		return NULL;
	lock(q);
	//double check
	if (q->head == NULL) {
		unlock(q);
		return NULL;
	}
	msg = q->head;
	q->head = NULL;
	q->tail = &q->head;
	unlock(q);
	atomic_xor(&q->size, q->size);
	return msg;
}

size_t
silly_queue_size(struct silly_queue *q)
{
	return q->size;
}

