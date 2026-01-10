#ifndef _LUA_STR_H
#define _LUA_STR_H

#include <stdint.h>
#include <lua.h>
#include <lauxlib.h>

struct luastr {
	const uint8_t *str;
	int len;
};

static inline void luastr_check(lua_State *L, int idx, struct luastr *s)
{
	size_t len;
	s->str = (const uint8_t *)luaL_checklstring(L, idx, &len);
	s->len = (int)len;
}

static inline void luastr_opt(lua_State *L, int idx, struct luastr *s)
{
	size_t len;
	s->str = (const uint8_t *)luaL_optlstring(L, idx, NULL, &len);
	s->len = (int)len;
}

static inline void luastr_get(lua_State *L, int idx, struct luastr *s)
{
	size_t len;
	s->str = (const uint8_t *)lua_tolstring(L, idx, &len);
	s->len = (int)len;
}

#endif