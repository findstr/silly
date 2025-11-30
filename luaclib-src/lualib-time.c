#include <unistd.h>
#include <assert.h>
#include <stdlib.h>
#include <stdio.h>
#include <stddef.h>
#include <string.h>
#include <sys/time.h>
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>

#include "silly.h"

static int lafter(lua_State *L)
{
	lua_Integer expire;
	uint64_t session;
	expire = luaL_checkinteger(L, 1);
	if (unlikely(expire > UINT32_MAX)) {
		return luaL_argerror(L, 1, "expire too large");
	}
	if (unlikely(expire < 0)) {
		expire = 0;
	}
	session = silly_timer_after(expire);
	lua_pushinteger(L, (lua_Integer)session);
	return 1;
}

static int lcancel(lua_State *L)
{
	uint64_t session = (uint64_t)luaL_checkinteger(L, 1);
	int ok = silly_timer_cancel(session);
	lua_pushboolean(L, ok);
	return 1;
}

static int lnow(lua_State *L)
{
	uint64_t now = silly_now();
	lua_pushinteger(L, now);
	return 1;
}

static int lmonotonic(lua_State *L)
{
	uint64_t monotonic = silly_monotonic();
	lua_pushinteger(L, monotonic);
	return 1;
}

SILLY_MOD_API int luaopen_silly_time_c(lua_State *L)
{
	luaL_Reg tbl[] = {
		{ "after",       lafter    },
		{ "cancel",      lcancel   },
		{ "now",         lnow      },
		{ "monotonic",   lmonotonic},
		{ NULL,          NULL      },
	};

	luaL_checkversion(L);
	luaL_newlib(L, tbl);
	lua_pushinteger(L, silly_messages()->timer_expire);
	lua_setfield(L, -2, "EXPIRE");
	return 1;
}