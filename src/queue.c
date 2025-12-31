#include <stdio.h>
#include "silly.h"
#include "message.h"
#include "spinlock.h"
#include "mem.h"
#include "queue.h"

struct queue {
	size_t size;
	struct silly_message **tail;
	struct silly_message *head;
	spinlock_t lock;
};

static inline void lock(struct queue *q)
{
	spinlock_lock(&q->lock);
}

static inline void unlock(struct queue *q)
{
	spinlock_unlock(&q->lock);
	return;
}

static inline void queue_init(struct queue *q)
{
	q->size = 0;
	q->head = NULL;
	q->tail = &q->head;
}

struct queue *queue_create()
{
	struct queue *q = (struct queue *)mem_alloc(sizeof(*q));
	spinlock_init(&q->lock);
	queue_init(q);
	return q;
}

void queue_clear(struct queue *q)
{
	struct silly_message *next, *tmp;
	next = queue_pop(q);
	while (next) {
		tmp = next;
		next = next->next;
		tmp->free(tmp);
	}
}

void queue_free(struct queue *q)
{
	queue_clear(q);
	spinlock_destroy(&q->lock);
	mem_free(q);
	return;
}

int queue_push(struct queue *q, struct silly_message *msg)
{
	int n;
	msg->next = NULL;
	lock(q);
	*q->tail = msg;
	q->tail = &msg->next;
	n = ++q->size;
	unlock(q);
	return n;
}

struct silly_message *queue_pop(struct queue *q)
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
	queue_init(q);
	unlock(q);
	return msg;
}

size_t queue_size(struct queue *q)
{
	return q->size;
}
