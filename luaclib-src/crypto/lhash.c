#include <assert.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <strings.h>
#include <lua.h>
#include <lauxlib.h>
#include <openssl/evp.h>
#include <openssl/err.h>
#include <openssl/pem.h>
#include "silly.h"
#include "md_cache.h"
#include "luastr.h"

#define METATABLE "silly.crypto.digest"

struct hash {
	const EVP_MD *md;
	EVP_MD_CTX *ctx;
};

static int lgc(lua_State *L)
{
	struct hash *c = luaL_checkudata(L, 1, METATABLE);
	if (c->ctx != NULL) {
		EVP_MD_CTX_free(c->ctx);
		c->ctx = NULL;
	}
	return 0;
}

/// new(alg)
static int lnew(lua_State *L)
{
	struct hash *c;
	const EVP_MD *md;
	EVP_MD_CTX *ctx;
	md = md_cache_get(L, 1);
	ctx = EVP_MD_CTX_create();
	if (ctx == NULL) {
		return luaL_error(L, "create hash context error");
	}
	if (EVP_DigestInit_ex(ctx, md, NULL) == 0) {
		return luaL_error(L, "hash init error: %s",
				  ERR_lib_error_string(ERR_get_error()));
	}
	c = lua_newuserdatauv(L, sizeof(*c), 0);
	luaL_setmetatable(L, METATABLE);
	c->md = md;
	c->ctx = ctx;
	return 1;
}

/// digest(alg, data)
static int lhash(lua_State *L)
{
	unsigned int outlen;
	unsigned char hash[EVP_MAX_MD_SIZE];
	struct luastr data;
	const EVP_MD *md;
	md = md_cache_get(L, 1);
	luastr_check(L, 2, &data);
	outlen = sizeof(hash);
	if (EVP_Digest(data.str, data.len, hash, &outlen, md, NULL) == 0) {
		return luaL_error(L, "hash digest error: %s",
				  ERR_lib_error_string(ERR_get_error()));
	}
	lua_pushlstring(L, (const char *)hash, outlen);
	return 1;
}

static int lxreset(lua_State *L)
{
	struct hash *c = luaL_checkudata(L, 1, METATABLE);
	if (EVP_MD_CTX_reset(c->ctx) == 0) {
		return luaL_error(L, "hash reset error: %s",
				  ERR_lib_error_string(ERR_get_error()));
	}
	if (EVP_DigestInit_ex(c->ctx, c->md, NULL) == 0) {
		return luaL_error(L, "hash init error: %s",
				  ERR_lib_error_string(ERR_get_error()));
	}
	return 0;
}

/// update(hash, data)
static int lxupdate(lua_State *L)
{
	int err;
	struct luastr data;
	struct hash *c = luaL_checkudata(L, 1, METATABLE);
	luastr_check(L, 2, &data);
	err = EVP_DigestUpdate(c->ctx, data.str, data.len);
	if (err == 0) {
		return luaL_error(L, "hash update error: %s",
				  ERR_lib_error_string(ERR_get_error()));
	}
	return 0;
}

/// final(hash)
static int lxfinal(lua_State *L)
{
	unsigned int outlen;
	unsigned char hash[EVP_MAX_MD_SIZE];
	struct hash *c = luaL_checkudata(L, 1, METATABLE);
	outlen = sizeof(hash);
	if (EVP_DigestFinal_ex(c->ctx, hash, &outlen) == 0) {
		return luaL_error(L, "hash final error: %s",
				  ERR_lib_error_string(ERR_get_error()));
	}
	lua_pushlstring(L, (const char *)hash, outlen);
	return 1;
}

/// digest(hash, data)
static int lxdigest(lua_State *L)
{
	unsigned int outlen;
	unsigned char hash[EVP_MAX_MD_SIZE];
	struct luastr data;
	struct hash *c = luaL_checkudata(L, 1, METATABLE);
	luastr_check(L, 2, &data);
	outlen = sizeof(hash);
	if (EVP_MD_CTX_reset(c->ctx) == 0) {
		return luaL_error(L, "hash context reset error: %s",
				  ERR_lib_error_string(ERR_get_error()));
	}

	if (EVP_DigestInit_ex(c->ctx, c->md, NULL) == 0) {
		return luaL_error(L, "hash init error: %s",
				  ERR_lib_error_string(ERR_get_error()));
	}
	if (EVP_DigestUpdate(c->ctx, data.str, data.len) == 0) {
		return luaL_error(L, "hash update error: %s",
				  ERR_lib_error_string(ERR_get_error()));
	}
	if (EVP_DigestFinal_ex(c->ctx, hash, &outlen) == 0) {
		return luaL_error(L, "hash final error: %s",
				  ERR_lib_error_string(ERR_get_error()));
	}
	lua_pushlstring(L, (const char *)hash, outlen);
	return 1;
}

SILLY_MOD_API int luaopen_silly_crypto_hash(lua_State *L)
{
	luaL_Reg tbl[] = {
		{ "new",    lnew     },
		{ "hash",   lhash    },
		// object methods
		{ "reset",  lxreset  },
		{ "update", lxupdate },
		{ "final",  lxfinal  },
		{ "digest", lxdigest },
		{ NULL,     NULL     },
	};
	luaL_checkversion(L);
	luaL_newlibtable(L, tbl);
	// new metatable
	luaL_newmetatable(L, METATABLE);
	lua_pushcfunction(L, lgc);
	lua_setfield(L, -2, "__gc");
	lua_pushvalue(L, -2);
	lua_setfield(L, -2, "__index");
	lua_pop(L, 1);
	// set funcs
	md_cache_new(L);
	luaL_setfuncs(L, tbl, 1);
#if OPENSSL_VERSION_NUMBER < 0x10100000L
	OpenSSL_add_all_digests();
#endif
	return 1;
}