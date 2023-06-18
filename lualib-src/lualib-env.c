#include <unistd.h>
#include <assert.h>
#include <stdlib.h>
#include <stdio.h>
#include <stddef.h>
#include <string.h>
#include <sys/time.h>
#include <sys/resource.h>
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>

#include "silly.h"
#include "compiler.h"
#include "silly_env.h"


static int
lget(lua_State *L)
{
	const char *key = luaL_checkstring(L, 1);
	const char *value = silly_env_get(key);
	if (value)
		lua_pushstring(L, value);
	else
		lua_pushnil(L);

	return 1;
}

static int
lset(lua_State *L)
{
	const char *key = luaL_checkstring(L, 1);
	const char *value = luaL_checkstring(L, 2);
	silly_env_set(key, value);
	return 0;
}

int
luaopen_sys_env(lua_State *L)
{
	luaL_Reg tbl[] = {
		{"get", lget},
		{"set", lset},
		//end
		{NULL, NULL},
	};

	luaL_checkversion(L);
	luaL_newlib(L, tbl);
	return 1;
}

