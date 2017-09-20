#ifndef _SILLY_WORKER_H
#define _SILLY_WORKER_H

struct silly_message;
struct lua_State;

void silly_worker_init();
void silly_worker_exit();

void silly_worker_start(const struct silly_config *config);

void silly_worker_push(struct silly_message *msg);
void silly_worker_dispatch();

uint32_t silly_worker_genid();
size_t silly_worker_msgsize();

void silly_worker_callback(void (*callback)(struct lua_State *L, struct silly_message *msg));

#endif

