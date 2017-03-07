#include <assert.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <lua.h>
#include <lauxlib.h>
#include "lsha1.h"
#include "sha256.h"
#include "aes.h"

static int
lrandomkey(lua_State *L)
{
	int i;
	char buff[8];

	for (i = 0; i < 8; i++)
		buff[i] = random() % 26 + 'a';

	lua_pushlstring(L, buff, 8);

	return 1;
}

#define AESKEY_LEN (32)
#define AESGROUP_LEN (16)
#define AESIV ("!*^$~)_+=-)(87^$#Dfhjklmnb<>,k./;KJl")

static void
aes_encode(uint8_t key[AESKEY_LEN], const uint8_t *src, uint8_t *dst, int sz)
{
	int i;
	int group;
	int last;
	uint8_t tail[AESGROUP_LEN];
	aes_context ctx;

	group = sz / AESGROUP_LEN;
	last = sz % AESGROUP_LEN;

	//CBC
	aes_set_key(&ctx, key, AESKEY_LEN * 8);
	for (i = 0; i < group; i++) {
		int gi = i * AESGROUP_LEN;
		aes_encrypt(&ctx, &src[gi], &dst[gi]);
	}

	//OFB
	if (last) {
		if (group) {
			memcpy(tail, &dst[(group - 1) * AESGROUP_LEN], sizeof(tail));
		} else {
			memcpy(tail, AESIV, sizeof(tail));
		}
		aes_encrypt(&ctx, tail, tail);
		for (i = 0; i < last; i++) {
			int gi = group * AESGROUP_LEN;
			dst[gi + i] = src[gi + i]^tail[i];
		}
	}
	return ;
}

static void
aes_decode(uint8_t key[AESKEY_LEN], const uint8_t *src, uint8_t *dst, int sz)
{
	int i;
	int group;
	int last;
	uint8_t tail[AESGROUP_LEN];
	aes_context ctx;

	group = sz / AESGROUP_LEN;
	last = sz % AESGROUP_LEN;

	aes_set_key(&ctx, key, AESKEY_LEN * 8);
	if (last) {
		if (group) {
			int gi = (group - 1) * AESGROUP_LEN;
			memcpy(tail, &src[gi], sizeof(tail));
		} else {
			memcpy(tail, AESIV, sizeof(tail));
		}
	}
	//CBC
	for (i = 0; i < group; i++) {
		int gi = i * AESGROUP_LEN;
		aes_decrypt(&ctx, &src[gi], &dst[gi]);
	}

	//OFB
	if (last) {
		aes_encrypt(&ctx, tail, tail);
		for (i = 0; i < last; i++) {
			int gi = group * AESGROUP_LEN;
			dst[gi + i] = src[gi + i]^tail[i];
		}
	}
	return ;
}

typedef void (* aes_func_t)(
				uint8_t key[AESKEY_LEN],
				const uint8_t *src,
				uint8_t *dst,
				int sz);

static int
aes_do(lua_State *L, aes_func_t func)
{
	uint8_t key[AESKEY_LEN];
	int data_type;
	size_t key_sz;
	const uint8_t *key_text;

	key_text = (uint8_t *)luaL_checklstring(L, 1, &key_sz);
	if (key_sz > AESKEY_LEN) {
		sha256_context ctx;
		sha256_starts(&ctx);
		sha256_update(&ctx, key_text, key_sz);
		sha256_finish(&ctx, key);
	} else {
		memset(key, 0, sizeof(key));
		memcpy(key, key_text, key_sz);
	}

	data_type = lua_type(L, 2);
	if (data_type == LUA_TSTRING) {
		size_t data_sz;
		const uint8_t *data = (const uint8_t *)luaL_checklstring(L, 2, &data_sz);
		uint8_t *recv = (uint8_t *)lua_newuserdata(L, data_sz);
		func(key, data, recv, data_sz);
		lua_pushlstring(L, (char *)recv, data_sz);
		return 1;
	} else if (data_type == LUA_TLIGHTUSERDATA) {
		uint8_t *data = (uint8_t *)lua_touserdata(L, 2);
		size_t data_sz = luaL_checkinteger(L, 3);
		func(key, data, data, data_sz);
		return 2;
	} else {
		return luaL_error(L, "Invalid content");
	}
}

static int
laesencode(lua_State *L)
{
	return aes_do(L, aes_encode);
}

static int
laesdecode(lua_State *L)
{
	return aes_do(L, aes_decode);
}

static inline char
dict(int n)
{
	static const char *dict =
		"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
	return dict[n];
}

static int
undict(int ch)
{
	int v;
	if (ch == '+')
		v = 62;
	else if (ch == '/')
		v = 63;
	else if (ch >= 'A' && ch <= 'Z')
		v = ch - 'A';
	else if (ch >= 'a' && ch <= 'z')
		v = ch - 'a' + 26;
	else if (ch >= '0' && ch <= '9')
		v = ch - '0' + 26 + 26;
	else //'='
		v = 0;
	return v;
}

static void
numtochar(char *dst, const char *src, int sz)
{
	int n = 0;
	switch (sz) {
	default:
		/* fall through */
	case 3:
		n |= src[2];
		/* fall through */
	case 2:
		n |= src[1] << 8;
		/* fall through */
	case 1:
		n |= src[0] << 16;
		break;
	case 0:
		assert(0);
		break;
	}
	dst[3] = dict(n & 0x3f);
	dst[2] = dict((n & (0x3f << 6)) >> 6);
	dst[1] = dict((n & (0x3f << 12)) >> 12);
	dst[0] = dict((n & (0x3f << 18)) >> 18);
}

static void
chartonum(char *dst, size_t sz, const char *src)
{
	int n = 0;
	n |= undict(src[3]);
	n |= undict(src[2]) << 6;
	n |= undict(src[1]) << 12;
	n |= undict(src[0]) << 18;
	switch (sz) {
	default:
		/* fall through */
	case 3:
		dst[2] = n & 0xff;
		/* fall through */
	case 2:
		dst[1] = (n >> 8) & 0xff;
		/* fall through */
	case 1:
		dst[0] = (n >> 16) & 0xff;
		break;
	case 0:
		assert(0);
		break;
	}
	return ;

}
int
lbase64encode(lua_State *L)
{
	const char *buff;
	size_t sz;
	int a, b;
	char *ret, *ptr;
	buff = luaL_checklstring(L, 1, &sz);
	a = sz / 3;
	b = sz % 3;
	int need = a + (b == 0 ? 0 : 1);
	need *= 4;
	ptr = ret = lua_newuserdata(L, need);
	while (a--) {
		numtochar(ptr, buff, 3);
		buff += 3;
		ptr += 4;
	}
	if (b) { // if b == 0perfect, just direct return
		numtochar(ptr, buff, b);
		ptr += 1 + b;
		while (ptr < (ret + need))
			*ptr++ = '=';
	}
	lua_pushlstring(L, ret, need);
	return 1;
}

int
lbase64decode(lua_State *L)
{
	int need;
	char *dst, *ptr1;
	const char *src, *ptr2;
	size_t sz;
	src = luaL_checklstring(L, 1, &sz);
	if (sz % 4 != 0)
		return luaL_error(L, "base64decode invalie param");
	if (sz == 0) {
		lua_pushliteral(L, "");
		return 1;
	}
	need = sz / 4 * 3;
	ptr2 = src + sz;
	while ((*(ptr2- 1) == '=') && (ptr2 > src)) {
		--ptr2;
		--need;
	};
	ptr1 = dst = lua_newuserdata(L, need);
	ptr2 = dst + need;
	while (ptr1 < ptr2) {
		chartonum(ptr1, ptr2 - ptr1, src);
		ptr1 += 3;
		src += 4;
	}
	lua_pushlstring(L, dst, need);
	return 1;
}

int
luaopen_crypt(lua_State *L)
{
	luaL_Reg tbl[] = {
		{"sha1", lsha1},
		{"randomkey", lrandomkey},
		{"hmac", lhmac_sha1},
		{"aesencode", laesencode},
		{"aesdecode", laesdecode},
		{"base64encode", lbase64encode},
		{"base64decode", lbase64decode},
		{NULL, NULL},
	};

	luaL_newlib(L, tbl);

	return 1;
}
