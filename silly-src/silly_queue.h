#ifndef _SILLY_QUEUE_H
#define _SILLY_QUEUE_H

struct silly_message;
struct silly_queue;

struct silly_queue *silly_queue_create();
void silly_queue_free(struct silly_queue *q);

//when return from silly_push, should not be free the msg
int silly_queue_push(struct silly_queue *q, struct silly_message *msg);

//after use the message returned by silly_pop, free it
struct silly_message *silly_queue_pop(struct silly_queue *q);

size_t silly_queue_size(struct silly_queue *q);

#endif


