#ifndef _SILLY_ADT_LUA_ASSERT
#define _SILLY_ADT_LUA_ASSERT

#include <lua.h>
#include <lauxlib.h>

#include "silly.h"

// Usage: luaL_assert(L, condition, "error message")
//        luaL_assert(L, condition, "error: %d", value)
#define luaL_assert(L, cond, ...) \
	do { \
		if (unlikely(!(cond))) \
			luaL_error(L, __VA_ARGS__); \
	} while (0)

#endif