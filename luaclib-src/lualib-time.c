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

static int ltimeout(lua_State *L)
{
	uint32_t expire;
	uint32_t userdata;
	uint64_t session;
	expire = luaL_checkinteger(L, 1);
	userdata = luaL_optinteger(L, 2, 0);
	session = silly_timer_after(expire, userdata);
	lua_pushinteger(L, (lua_Integer)session);
	return 1;
}

static int ltimercancel(lua_State *L)
{
	uint32_t ud;
	uint64_t session = (uint64_t)luaL_checkinteger(L, 1);
	int ok = silly_timer_cancel(session, &ud);
	if (ok) {
		lua_pushinteger(L, ud);
	} else {
		lua_pushnil(L);
	}
	return 1;
}

static int ltimenow(lua_State *L)
{
	uint64_t now = silly_now();
	lua_pushinteger(L, now);
	return 1;
}

static int ltimemonotonic(lua_State *L)
{
	uint64_t monotonic = silly_monotonic();
	lua_pushinteger(L, monotonic);
	return 1;
}

SILLY_MOD_API int luaopen_silly_time_c(lua_State *L)
{
	luaL_Reg tbl[] = {
		{ "timeout",     ltimeout       },
                { "timercancel", ltimercancel   },
		{ "now",         ltimenow       },
                { "monotonic",   ltimemonotonic },
		{ NULL,          NULL           },
	};

	luaL_checkversion(L);
	luaL_newlib(L, tbl);
	lua_pushinteger(L, silly_messages()->timer_expire);
	lua_setfield(L, -2, "EXPIRE");
	return 1;
}