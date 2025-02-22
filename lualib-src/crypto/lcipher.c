#include <assert.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <strings.h>
#include <lua.h>
#include <lauxlib.h>
#include <openssl/evp.h>
#include <openssl/aes.h>
#include <openssl/err.h>
#include "silly_malloc.h"
#include "luastr.h"

#define METATABLE "core.crypto.cipher"

struct cipher {
	EVP_CIPHER_CTX *ctx;
	const EVP_CIPHER *cipher;
	uint8_t *buf;
	int size;
	int cap;
	uint8_t enc;
	int8_t padding;
};

static const EVP_CIPHER *get_cipher(lua_State *L)
{
	const EVP_CIPHER *cipher;
	struct luastr alg;
	luastr_check(L, 1, &alg);
	lua_pushvalue(L, 1);
	lua_gettable(L, lua_upvalueindex(1));
	if (lua_isnil(L, -1)) {
		cipher = EVP_get_cipherbyname((const char *)alg.str);
		if (cipher != NULL) {
			lua_pushvalue(L, 1);
			lua_pushlightuserdata(L, (void *)(uintptr_t)cipher);
			lua_settable(L, lua_upvalueindex(1));
		}
	} else {
		cipher = lua_touserdata(L, -1);
	}
	if (cipher == NULL) {
		luaL_error(L, "unkonwn algorithm: %s", alg.str);
		assert(0); // for lint friendly
	}
	lua_pop(L, 1);
	return cipher;
}

static int lgc(lua_State *L)
{
	struct cipher *c = luaL_checkudata(L, 1, METATABLE);
	if (c->ctx != NULL) {
		EVP_CIPHER_CTX_free(c->ctx);
		c->ctx = NULL;
	}
	if (c->buf != NULL) {
		silly_free(c->buf);
		c->buf = NULL;
		c->size = 0;
		c->cap = 0;
	}
	return 0;
}

static void check_iv(lua_State *L, int stk, struct luastr *iv,
		     const EVP_CIPHER *cipher)
{
	if (lua_isnoneornil(L, stk)) {
		iv->str = NULL;
		iv->len = 0;
		return;
	}
	luastr_check(L, stk, iv);
	if (iv->len != EVP_CIPHER_get_iv_length(cipher)) {
		luaL_error(L, "iv length need:%d got:%d",
			   EVP_CIPHER_get_iv_length(cipher), iv->len);
	}
}

static void check_key(lua_State *L, int stk, struct luastr *key,
		      const EVP_CIPHER *cipher)
{
	luastr_check(L, stk, key);
	if (key->len != EVP_CIPHER_key_length(cipher)) {
		luaL_error(L, "key length need:%d got:%d",
			   EVP_CIPHER_key_length(cipher), key->len);
	}
}

/// new(alg, key, iv)
static int lnewx(lua_State *L, int enc)
{
	const EVP_CIPHER *cipher;
	EVP_CIPHER_CTX *ctx;
	struct luastr key, iv;
	luastr_check(L, 2, &key);
	cipher = get_cipher(L);
	check_key(L, 2, &key, cipher);
	check_iv(L, 3, &iv, cipher);
	ctx = EVP_CIPHER_CTX_new();
	if (ctx == NULL) {
		return luaL_error(L, "cipher create context failed");
	}
	if (EVP_CipherInit_ex(ctx, cipher, NULL, key.str, iv.str, enc) == 0) {
		EVP_CIPHER_CTX_free(ctx);
		return luaL_error(L, "cipher init error: %s",
				  ERR_lib_error_string(ERR_get_error()));
	}
	struct cipher *c = lua_newuserdatauv(L, sizeof(*c), 0);
	luaL_setmetatable(L, METATABLE);
	c->ctx = ctx;
	c->cipher = cipher;
	c->buf = NULL;
	c->size = 0;
	c->cap = 0;
	c->enc = (uint8_t)enc;
	c->padding = -1;
	return 1;
}

static int lnewenc(lua_State *L)
{
	return lnewx(L, 1);
}

static int lnewdec(lua_State *L)
{
	return lnewx(L, 0);
}

static void try_expand_buffer(struct cipher *c, int len)
{
	len += EVP_CIPHER_CTX_get_block_size(c->ctx);
	if (c->cap < c->size + len) {
		c->cap = len + c->size;
		c->buf = silly_realloc(c->buf, c->cap);
	}
}

/// reset(cipher, key, iv)
static int lxreset(lua_State *L)
{
	struct luastr key, iv;
	struct cipher *c = luaL_checkudata(L, 1, METATABLE);
	check_key(L, 2, &key, c->cipher);
	check_iv(L, 3, &iv, c->cipher);
	EVP_CIPHER_CTX_reset(c->ctx);
	if (EVP_CipherInit_ex(c->ctx, c->cipher, NULL, key.str, iv.str,
			      c->enc) == 0) {
		return luaL_error(L, "cipher reset error: %s",
				  ERR_lib_error_string(ERR_get_error()));
	}
	if (c->padding >= 0 &&
	    EVP_CIPHER_CTX_set_padding(c->ctx, c->padding) == 0) {
		return luaL_error(L, "cipher set padding error: %s",
				  ERR_lib_error_string(ERR_get_error()));
	}
	c->size = 0;
	return 0;
}

/// update(cipher, data)
static int lxupdate(lua_State *L)
{
	int outlen;
	struct luastr data;
	struct cipher *c = luaL_checkudata(L, 1, METATABLE);
	luastr_check(L, 2, &data);
	try_expand_buffer(c, data.len);
	if (EVP_CipherUpdate(c->ctx, &c->buf[c->size], &outlen, data.str,
			     data.len) == 0) {
		return luaL_error(L, "cipher update error: %s",
				  ERR_lib_error_string(ERR_get_error()));
	}
	c->size += outlen;
	return 0;
}

/// final(cipher, data?)
static int lxfinal(lua_State *L)
{
	int outlen;
	struct cipher *c = luaL_checkudata(L, 1, METATABLE);
	if (lua_gettop(L) > 1) {
		struct luastr data;
		luastr_check(L, 2, &data);
		try_expand_buffer(c, data.len);
		if (EVP_CipherUpdate(c->ctx, &c->buf[c->size], &outlen,
				     data.str, data.len) == 0) {
			return luaL_error(
				L, "cipher update error: %s",
				ERR_lib_error_string(ERR_get_error()));
		}
		c->size += outlen;
	}
	try_expand_buffer(c, 0);
	if (EVP_CipherFinal_ex(c->ctx, &c->buf[c->size], &outlen) == 0) {
		lua_pushnil(L);
		return 1;
	}
	c->size += outlen;
	lua_pushlstring(L, (const char *)c->buf, c->size);
	c->size = 0;
	return 1;
}

static int lxsetpadding(lua_State *L)
{
	struct cipher *c = luaL_checkudata(L, 1, METATABLE);
	int padding = luaL_checkinteger(L, 2);
	if (EVP_CIPHER_CTX_set_padding(c->ctx, padding) == 0) {
		return luaL_error(L, "cipher set padding error: %s",
				  ERR_lib_error_string(ERR_get_error()));
	}
	c->padding = padding;
	return 0;
}

static int lxsetaad(lua_State *L)
{
	int outlen;
	struct luastr aad;
	struct cipher *c = luaL_checkudata(L, 1, METATABLE);
	luastr_check(L, 2, &aad);
	if (EVP_CipherUpdate(c->ctx, NULL, &outlen, aad.str, aad.len) == 0) {
		return luaL_error(L, "cipher aad error: %s",
				  ERR_lib_error_string(ERR_get_error()));
	}
	return 0;
}

static int lxsettag(lua_State *L)
{
	struct luastr tag;
	struct cipher *c = luaL_checkudata(L, 1, METATABLE);
	luastr_check(L, 2, &tag);
	if (EVP_CIPHER_CTX_ctrl(c->ctx, EVP_CTRL_AEAD_SET_TAG, tag.len,
				(void *)tag.str) == 0) {
		return luaL_error(L, "cipher tag error: %s",
				  ERR_lib_error_string(ERR_get_error()));
	}
	return 0;
}

static int lxtag(lua_State *L)
{
	int ret;
	struct cipher *c = luaL_checkudata(L, 1, METATABLE);
	int taglen = EVP_CIPHER_CTX_tag_length(c->ctx);
	try_expand_buffer(c, taglen);
	ret = EVP_CIPHER_CTX_ctrl(c->ctx, EVP_CTRL_AEAD_GET_TAG, taglen,
				  &c->buf[c->size]);
	if (ret == 0) {
		return luaL_error(L, "cipher tag error: %s",
				  ERR_lib_error_string(ERR_get_error()));
	}
	lua_pushlstring(L, (const char *)&c->buf[c->size], taglen);
	return 1;
}

int luaopen_core_crypto_cipher(lua_State *L)
{
	luaL_Reg tbl[] = {
		{ "encryptor",  lnewenc      },
		{ "decryptor",  lnewdec      },
		// object method
		{ "reset",      lxreset      },
		{ "update",     lxupdate     },
		{ "final",      lxfinal      },
		{ "setpadding", lxsetpadding },
		// AEAD
		{ "setaad",     lxsetaad     },
		{ "settag",     lxsettag     },
		{ "tag",        lxtag        },
		{ NULL,         NULL         },
	};
	luaL_newlibtable(L, tbl);
	// create metatable
	luaL_newmetatable(L, METATABLE);
	lua_pushcfunction(L, lgc);
	lua_setfield(L, -2, "__gc");
	lua_pushvalue(L, -2);
	lua_setfield(L, -2, "__index");
	lua_pop(L, 1);
	// set methods
	lua_newtable(L);
	luaL_setfuncs(L, tbl, 1);
#if OPENSSL_VERSION_NUMBER < 0x10100000L
	OpenSSL_add_all_ciphers();
#endif
	return 1;
}
