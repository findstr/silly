#include <assert.h>
#include <stdint.h>
#include <string.h>
#include <strings.h>
#include <lua.h>
#include <lauxlib.h>

#include <openssl/pem.h>
#include <openssl/err.h>
#include <openssl/evp.h>

#include "silly.h"

static int lxor(lua_State *L)
{
	const char *key;
	size_t key_len;
	const char *dat;
	size_t dat_len;
	luaL_Buffer b;
	key = luaL_checklstring(L, 1, &key_len);
	dat = luaL_checklstring(L, 2, &dat_len);
	luaL_buffinitsize(L, &b, dat_len);
	luaL_argcheck(L, key_len > 0, 1, "crypto.xor key can't be empty");
	for (size_t i = 0; i < dat_len; i++) {
		uint8_t k = key[i % key_len];
		uint8_t c = (uint8_t)dat[i] ^ k;
		luaL_addchar(&b, c);
	}
	luaL_pushresult(&b);
	return 1;
}

SILLY_MOD_API int luaopen_silly_crypto_utils(lua_State *L)
{
	luaL_Reg tbl[] = {
		{ "xor", lxor },
		{ NULL,  NULL },
	};
	luaL_checkversion(L);
	luaL_newlib(L, tbl);
	return 1;
}
