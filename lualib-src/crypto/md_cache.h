#ifndef _DIGEST_CACHE_H
#define _DIGEST_CACHE_H

#include <lua.h>
#include <lauxlib.h>
#include <openssl/evp.h>
#include "luastr.h"


static inline void md_cache_new(lua_State *L) {
	const char *k = "crypto.hash.mds";
	lua_getfield(L, LUA_REGISTRYINDEX, k);
	if (lua_isnil(L, -1)) {
		lua_pop(L, 1);
		lua_newtable(L);
		lua_pushvalue(L, -1);
		lua_setfield(L, LUA_REGISTRYINDEX, k);
	}
}

static inline const EVP_MD *md_cache_get(lua_State *L, int stk_alg)
{
	const EVP_MD *md;
	lua_pushvalue(L, stk_alg);
	lua_gettable(L, lua_upvalueindex(1));
	if (lua_isnil(L, -1)) {
		struct luastr alg;
		luastr_check(L, 1, &alg);
		md = EVP_get_digestbyname((const char *)alg.str);
		if (md != NULL) {
			lua_pushvalue(L, 1);
			lua_pushlightuserdata(L, (void *)(uintptr_t)md);
			lua_settable(L, lua_upvalueindex(1));
		}
	} else {
		md = lua_touserdata(L, -1);
	}
	lua_pop(L, 1);
	return md;
}

#endif
