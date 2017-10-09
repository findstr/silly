#include <lua.h>
#include <lauxlib.h>

#include "silly_malloc.h"

#include "silly_env.h"

struct silly_env {
	lua_State *L;
};

static struct silly_env *E;

const char *silly_env_get(const char *key)
{
	const char *value;
	lua_State *L = E->L;
	lua_getglobal(L, key);
	value = lua_tostring(L, -1);
	lua_pop(L, 1);
	return value;
}

void silly_env_set(const char *key, const char *value)
{
	lua_State *L = E->L;
	lua_pushstring(L, value);
	lua_setglobal(L, key);
	return ;
}


int
silly_env_init()
{
	E = (struct silly_env *)silly_malloc(sizeof(*E));
	E->L = luaL_newstate();
	return 0;
}

void
silly_env_exit()
{
	lua_close(E->L);
	silly_free(E);
	return ;
}

