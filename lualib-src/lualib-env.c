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
#include "silly_worker.h"

static const char *load_config = "\
	local env, file = ...\
	local config = {}\
	local function eval(parent, tbl)\
		for k, v in pairs(tbl) do\
			if #parent > 0 then\
				k = parent .. '.' .. tostring(k)\
			end\
			if type(v) == 'table' then\
				eval(k, v)\
			elseif not env[k] then\
				env[k] = v\
			end\
		end\
		return t\
	end\
	local function include(name)\
		local f = io.open(name, 'r')\
		if not f then\
			error('open config error of file:' .. name)\
		end\
		local code = f:read('a')\
		if not code then\
			error('read config error of file:' .. name)\
		end\
		f:close()\
		assert(load(code, name, 't', config))()\
		return \
	end\
	config.include = include\
	config.ENV = os.getenv\
	include(file)\
	config.include = nil\
	config.ENV = nil\
	eval('', config)\
	";

static const char *skipcode(const char *str)
{
	while (*str && *str++ != ']')
		;
	if (*str)
		str += 3;
	return str;
}

static int lload(lua_State *L)
{
	int err;
	err = luaL_loadstring(L, load_config);
	assert(err == LUA_OK);
	lua_pushvalue(L, lua_upvalueindex(1)); //env_table
	lua_pushvalue(L, 1);
	err = lua_pcall(L, 2, 0, 0);
	if (err != LUA_OK) {
		const char *err = lua_tostring(L, -1);
		err = skipcode(err);
		lua_pushstring(L, err);
		lua_replace(L, -2);
	} else {
		lua_pushnil(L);
	}
	return 1;
}

static int lget(lua_State *L)
{
	lua_pushvalue(L, lua_upvalueindex(1)); //env_table
	lua_pushvalue(L, 1);
	lua_gettable(L, -2);
	return 1;
}

static int lset(lua_State *L)
{
	lua_pushvalue(L, lua_upvalueindex(1)); //env_table
	lua_pushvalue(L, 1);
	lua_pushvalue(L, 2);
	lua_settable(L, -3);
	return 0;
}

static void load_args(lua_State *L)
{
	int i, argc;
	char **argv;
	argv = silly_worker_args(&argc);
	for (i = 0; i < argc; i++) {
		const char *k, *v;
		char *str = argv[i];
		if (strlen(str) <= 2 || str[0] != '-' || str[1] != '-') {
			continue;
		}
		k = strtok(&str[2], "=");
		v = strtok(NULL, "=");
		if (k != NULL && v != NULL) {
			lua_pushstring(L, k);
			lua_pushstring(L, v);
			lua_settable(L, -3);
		}
	}
}

int luaopen_core_env(lua_State *L)
{
	luaL_Reg tbl[] = {
		{ "load", lload },
		{ "get",  lget  },
		{ "set",  lset  },
		//end
		{ NULL,   NULL  },
	};
	luaL_checkversion(L);
	luaL_newlibtable(L, tbl);
	lua_newtable(L);
	load_args(L);
	luaL_setfuncs(L, tbl, 1);
	return 1;
}
