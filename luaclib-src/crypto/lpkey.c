#include <assert.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <strings.h>
#include <lua.h>
#include <lauxlib.h>
#include <openssl/err.h>
#include <openssl/rsa.h>

#include "silly.h"
#include "md_cache.h"
#include "luastr.h"
#include "pkey.h"

#define METATABLE "silly.crypto.pkey"

struct pkey {
	EVP_PKEY *key;
};

static int lnew(lua_State *L)
{
	EVP_PKEY *evp_pkey;
	struct pkey *pkey_obj;
	struct luastr key;
	struct luastr passwd;
	luastr_check(L, 1, &key);
	if (lua_gettop(L) == 2) {
		luastr_check(L, 2, &passwd);
	} else {
		passwd.str = NULL;
		passwd.len = 0;
	}
	evp_pkey = pkey_load(&key, &passwd);
	if (evp_pkey == NULL) {
		const char *err = ERR_lib_error_string(ERR_get_error());
		return luaL_error(L, "load key error: %s", err);
	}
	pkey_obj = (struct pkey *)lua_newuserdata(L, sizeof(struct pkey));
	pkey_obj->key = evp_pkey;
	luaL_setmetatable(L, METATABLE);
	return 1;
}

/// gc(pkey)
static int lxgc(lua_State *L)
{
	struct pkey *pkey;
	pkey = (struct pkey *)luaL_checkudata(L, 1, METATABLE);
	if (pkey->key) {
		EVP_PKEY_free(pkey->key);
		pkey->key = NULL;
	}
	return 0;
}

/// sign(pkey, message, alg)
static int lxsign(lua_State *L)
{
	int ret;
	EVP_MD_CTX *ctx;
	const EVP_MD *md;
	struct pkey *pkey;
	struct luastr message;
	uint8_t *ptr;
	size_t sig_len = 0;
	luaL_Buffer buf;

	pkey = (struct pkey *)luaL_checkudata(L, 1, METATABLE);
	luastr_check(L, 2, &message);
	md = md_cache_get(L, 3);
	ctx = EVP_MD_CTX_new();
	if (ctx == NULL) {
		const char *err = ERR_lib_error_string(ERR_get_error());
		return luaL_error(L, "EVP_MD_CTX_new error:%s", err);
	}
	ret = EVP_DigestSignInit(ctx, NULL, md, NULL, pkey->key) == 1 &&
	      EVP_DigestSignUpdate(ctx, message.str, message.len) == 1 &&
	      EVP_DigestSignFinal(ctx, NULL, &sig_len) == 1;
	if (!ret) {
		EVP_MD_CTX_free(ctx);
		const char *err = ERR_lib_error_string(ERR_get_error());
		return luaL_error(L, "sign error:%s", err);
	}
	ptr = (uint8_t *)luaL_buffinitsize(L, &buf, sig_len);
	EVP_DigestSignFinal(ctx, ptr, &sig_len);
	EVP_MD_CTX_free(ctx);
	luaL_pushresultsize(&buf, sig_len);
	return 1;
}

/// verify(pkey, message, signature, alg)
static int lxverify(lua_State *L)
{
	int ret, verify;
	const EVP_MD *md;
	EVP_MD_CTX *ctx;
	struct pkey *pkey;
	struct luastr message;
	struct luastr signature;

	pkey = (struct pkey *)luaL_checkudata(L, 1, METATABLE);
	luastr_check(L, 2, &message);
	luastr_check(L, 3, &signature);
	md = md_cache_get(L, 4);
	ctx = EVP_MD_CTX_new();
	if (ctx == NULL) {
		const char *err = ERR_lib_error_string(ERR_get_error());
		return luaL_error(L, "EVP_MD_CTX_new error:%s", err);
	}
	ret = EVP_DigestVerifyInit(ctx, NULL, md, NULL, pkey->key) == 1 &&
	      EVP_DigestVerifyUpdate(ctx, message.str, message.len) == 1;
	verify = EVP_DigestVerifyFinal(ctx, signature.str, signature.len) == 1;
	EVP_MD_CTX_free(ctx);
	if (!ret && verify < 0) {
		const char *err = ERR_lib_error_string(ERR_get_error());
		return luaL_error(L, "verify error:%s", err);
	}
	lua_pushboolean(L, verify);
	return 1;
}

SILLY_MOD_API int luaopen_silly_crypto_pkey(lua_State *L)
{
	luaL_Reg tbl[] = {
		{ "new",    lnew     },
		// object methods
		{ "sign",   lxsign   },
		{ "verify", lxverify },
		{ NULL,     NULL     },
	};
	luaL_checkversion(L);
	luaL_newlibtable(L, tbl);
	// new metatable
	luaL_newmetatable(L, METATABLE);
	lua_pushcfunction(L, lxgc);
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
