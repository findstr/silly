#include <limits.h>
#include <stdlib.h>
#include <lua.h>
#include <lauxlib.h>
#include <openssl/rand.h>

#include "silly.h"

static int lbytes(lua_State *L)
{
	luaL_Buffer b;
	lua_Integer n;
	unsigned char *data;
	n = luaL_checkinteger(L, 1);
	luaL_argcheck(L, n >= 0 && n <= INT_MAX, 1, "random byte length is out of range");
	data = (unsigned char *)luaL_buffinitsize(L, &b, (size_t)n);
	if (n > 0 && RAND_bytes(data, (int)n) != 1)
		return luaL_error(L, "RAND_bytes failed");
	luaL_pushresultsize(&b, (size_t)n);
	return 1;
}

static int ltext(lua_State *L)
{
	luaL_Buffer b;
	lua_Integer n;
	char *data;
	n = luaL_checkinteger(L, 1);
	luaL_argcheck(L, n >= 0 && n <= INT_MAX, 1, "random text length is out of range");
	data = luaL_buffinitsize(L, &b, (size_t)n);
	for (lua_Integer i = 0; i < n; i++)
		data[i] = 'a' + random() % 26;
	luaL_pushresultsize(&b, (size_t)n);
	return 1;
}

SILLY_MOD_API int luaopen_silly_crypto_random(lua_State *L)
{
	luaL_Reg tbl[] = {
		{ "bytes", lbytes },
		{ "text",  ltext  },
		{ NULL,    NULL   },
	};
	luaL_checkversion(L);
	luaL_newlib(L, tbl);
	return 1;
}
