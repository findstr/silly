#ifndef _QUEUE_H
#define _QUEUE_H

struct silly_message;
struct queue;

struct queue *queue_create();
void queue_free(struct queue *q);

//when return from silly_push, should not be free the msg
int queue_push(struct queue *q, struct silly_message *msg);

//after use the message returned by silly_pop, free it
struct silly_message *queue_pop(struct queue *q);

size_t queue_size(struct queue *q);

#endif
