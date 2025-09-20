#ifndef _WORKER_H
#define _WORKER_H
#include <lua.h>
#include "silly.h"
#include "args.h"

void worker_init();
void worker_exit();
void worker_start(const struct boot_args *config);

void worker_push(struct silly_message *msg);
void worker_dispatch();

uint32_t worker_alloc_id();
size_t worker_msg_size();

uint32_t worker_process_id();
void worker_resume(lua_State *L);
void worker_warn_endless();

char **worker_args(int *argc);

void worker_callback(void (*callback)(struct lua_State *L,
				      struct silly_message *msg));

void worker_callback_table(lua_State *L);
void worker_error_table(lua_State *L);
void worker_push_error(lua_State *L, int stk, int code);
void worker_reset();
#endif
