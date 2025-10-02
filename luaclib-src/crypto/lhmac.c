#include <assert.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <strings.h>
#include <lua.h>
#include <lauxlib.h>
#include <openssl/hmac.h>
#include <openssl/err.h>

#include "silly.h"
#include "md_cache.h"
#include "luastr.h"

/// digest(key, msg, alg)
static int ldigest(lua_State *L)
{
	struct luastr key;
	struct luastr msg;
	const EVP_MD *md;
	unsigned char hash[EVP_MAX_MD_SIZE];
	unsigned int hash_len;
	luastr_check(L, 1, &key);
	luastr_check(L, 2, &msg);
	md = md_cache_get(L, 3);
#if OPENSSL_VERSION_NUMBER >= 0x30000000L
	if (!HMAC(md, &key.str[0], key.len, &msg.str[0], msg.len, hash,
		  &hash_len)) {
		return luaL_error(L, "HMAC Generation failed");
	}
#else
	HMAC_CTX *hmac = HMAC_CTX_new();
	if (hmac == NULL) {
		return luaL_error(L, "HMAC_CTX_new failed");
	}
	if (HMAC_Init_ex(hmac, &key.str[0], key.len, md, NULL) == 0) {
		HMAC_CTX_free(hmac);
		return luaL_error(L, "HMAC_Init_ex failed");
	}
	if (HMAC_Update(hmac, (unsigned char *)&msg.str[0], msg.len) == 0) {
		HMAC_CTX_free(hmac);
		return luaL_error(L, "HMAC_Update failed");
	}
	if (HMAC_Final(hmac, hash, &hash_len) == 0) {
		HMAC_CTX_free(hmac);
		return luaL_error(L, "HMAC_Final failed");
	}
	HMAC_CTX_free(hmac);
#endif
	lua_pushlstring(L, (const char *)hash, hash_len);
	return 1;
}

SILLY_MOD_API int luaopen_silly_crypto_hmac(lua_State *L)
{
	luaL_Reg tbl[] = {
		{ "digest", ldigest },
		{ NULL,     NULL    },
	};
	luaL_checkversion(L);
	luaL_newlibtable(L, tbl);
	md_cache_new(L);
	luaL_setfuncs(L, tbl, 1);
#if OPENSSL_VERSION_NUMBER < 0x10100000L
	OpenSSL_add_all_digests();
#endif
	return 1;
}
