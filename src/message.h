#ifndef _MESSAGE_H_
#define _MESSAGE_H_

#include <lua.h>
#include "compiler.h"

struct silly_message {
	int type;
	struct silly_message *next;
	int (*unpack)(lua_State *L, struct silly_message *msg);
	/* parameter is void* (not silly_message*) to match allocator's free
	 * signature, allowing direct assignment like msg->free = free */
	void (*free)(void *ptr);
};

int message_new_type();

#endif