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
#include "compiler.h"
#include "silly_log.h"
#include "silly_run.h"
#include "silly_worker.h"
#include "silly_socket.h"
#include "silly_malloc.h"
#include "silly_timer.h"

static int ltimenow(lua_State *L)
{
	uint64_t now = silly_timer_now();
	lua_pushinteger(L, now);
	return 1;
}

static int ltimenowsec(lua_State *L)
{
	uint64_t now = silly_timer_nowsec();
	lua_pushinteger(L, now);
	return 1;
}

static int ltimemonotonic(lua_State *L)
{
	uint64_t monotonic = silly_timer_monotonic();
	lua_pushinteger(L, monotonic);
	return 1;
}

static int ltimemonotonicsec(lua_State *L)
{
	uint64_t monotonic = silly_timer_monotonicsec();
	lua_pushinteger(L, monotonic);
	return 1;
}

int luaopen_core_time(lua_State *L)
{
	luaL_Reg tbl[] = {
		{ "now",          ltimenow          },
		{ "nowsec",       ltimenowsec       },
		{ "monotonic",    ltimemonotonic    },
		{ "monotonicsec", ltimemonotonicsec },
		//end
		{ NULL,           NULL              },
	};

	luaL_checkversion(L);
	luaL_newlib(L, tbl);
	return 1;
}
