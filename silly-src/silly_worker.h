#ifndef _SILLY_WORKER_H
#define _SILLY_WORKER_H

#include "silly_message.h"

struct silly_worker;
struct lua_State;

struct silly_worker *silly_worker_create(int workid);
void silly_worker_free(struct silly_worker *w);

int silly_worker_getid(struct silly_worker *w);

int silly_worker_push(struct silly_worker *w, struct silly_message *msg);

int silly_worker_start(struct silly_worker *w, const char *bootstrap, const char *libpath, const char *clibpath);
void silly_worker_stop(struct silly_worker *w);

int silly_worker_dispatch(struct silly_worker *w);

void silly_worker_register(struct silly_worker *w, void (*cb)(struct lua_State *L, struct silly_message *msg), void (*exit)(struct lua_State *L));

#endif

