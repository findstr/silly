#include <assert.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <lua.h>
#include <lauxlib.h>
#include "md5.h"
#include "sha256.h"
#include "aes.h"
#include "lsha1.h"

char num_to_char[] = "0123456789abcdef";

static int
lmd5(lua_State *L)
{
	size_t sz;
	uint8_t out[16];
	char str[2*16];
	const uint8_t *dat;
	unsigned i = 0, j = 0;
	struct MD5Context ctx;
	dat = (const uint8_t *)luaL_checklstring(L, 1, &sz);
	MD5Init(&ctx);
	MD5Update(&ctx, dat, sz);
	MD5Final(out, &ctx);
	while (i < sizeof(out)) {
		unsigned char n = out[i++];
		str[j++] = num_to_char[n >> 4];
		str[j++] = num_to_char[n & 0xf];
	}
	lua_pushlstring(L, str, j);
	return 1;
}

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

#define	AESBUFF_LEN (512)
#define AESKEY_LEN (32)
#define AES128_KEY (16)
#define AES192_KEY (24)
#define AES256_KEY (32)
#define AESGROUP_LEN (16)
#define	AESGROUP_LEN_POWER (4)
#define AESIV ((uint32_t *)("!*^$~)_+=-)(87^$#Dfhjklmnb<>,k./;KJl"))

static void
aes_encode(const uint8_t *key, int keybits,
	const uint32_t *iv,
	const uint8_t *src, uint8_t *dst, int sz)
{
	int i;
	int group;
	int last;
	uint8_t tail[AESGROUP_LEN];
	aes_context ctx;
	group = sz >> AESGROUP_LEN_POWER;
	last = sz & (AESGROUP_LEN - 1);
	//CBC
	aes_set_key(&ctx, key, keybits);
	for (i = 0; i < group; i++) {
		const uint32_t *from = (uint32_t *)src;
		uint32_t *to = (uint32_t *)dst;
		to[0] = from[0] ^ iv[0];
		to[1] = from[1] ^ iv[1];
		to[2] = from[2] ^ iv[2];
		to[3] = from[3] ^ iv[3];
		aes_encrypt(&ctx, dst, dst);
		iv = (const uint32_t *)dst;
		src += AESGROUP_LEN;
		dst += AESGROUP_LEN;
	}
	if (last == 0)
		return ;
	//OFB
	aes_encrypt(&ctx, (uint8_t *)iv, tail);
	for (i = 0; i < last; i++)
		dst[i] = src[i] ^ tail[i];
	return ;
}

static void
aes_decode(const uint8_t *key, int keybits,
	const uint32_t *iv,
	const uint8_t *src, uint8_t *dst, int sz)
{
	int i;
	int last;
	int group;
	uint32_t *ptr32;
	const uint32_t *ivptr;
	uint8_t tail[AESGROUP_LEN];
	aes_context ctx;
	src += sz;
	dst += sz;
	group = sz >> AESGROUP_LEN_POWER;
	last = sz & (AESGROUP_LEN - 1);
	aes_set_key(&ctx, key, keybits);
	//OFB
	if (last != 0) {
		src = src - last;
		dst = dst - last;
		ivptr = group == 0 ? iv : (uint32_t *)(src - AESGROUP_LEN);
		aes_encrypt(&ctx, (const uint8_t *)ivptr, tail);
		for (i = 0; i < last; i++)
			dst[i] = src[i] ^ tail[i];
	}
	if (group == 0)
		return ;
	//CBC
	src -= AESGROUP_LEN;
	dst -= AESGROUP_LEN;
	while (group > 1) {
		ivptr = (uint32_t *)(src - AESGROUP_LEN);
		aes_decrypt(&ctx, src, dst);
		ptr32 = (uint32_t *)dst;
		ptr32[0] = ptr32[0] ^ ivptr[0];
		ptr32[1] = ptr32[1] ^ ivptr[1];
		ptr32[2] = ptr32[2] ^ ivptr[2];
		ptr32[3] = ptr32[3] ^ ivptr[3];
		src = (uint8_t *)ivptr;
		dst -= AESGROUP_LEN;
		--group;
	}
	aes_decrypt(&ctx, src, dst);
	ptr32 = (uint32_t *)dst;
	ptr32[0] = ptr32[0] ^ iv[0];
	ptr32[1] = ptr32[1] ^ iv[1];
	ptr32[2] = ptr32[2] ^ iv[2];
	ptr32[3] = ptr32[3] ^ iv[3];
	return ;
}

typedef void (* aes_func_t)(
	const uint8_t *key, int keybits,
	const uint32_t *iv,
	const uint8_t *src, uint8_t *dst,int sz);

static inline uint8_t *
aes_getbuffer(lua_State *L, size_t need)
{
	uint8_t *data;
	int idx = lua_upvalueindex(1);
	size_t total = lua_rawlen(L, idx);
	if (total < need) {
		data = lua_newuserdata(L, need);
		lua_replace(L, idx);
	} else {
		data = lua_touserdata(L, idx);
	}
	return data;
}

static inline const uint32_t *
aes_getiv(lua_State *L, int idx, uint8_t group[AESGROUP_LEN])
{
	size_t size;
	const uint8_t *iv;
	int type = lua_type(L, idx);
	if (type != LUA_TSTRING) {
		return AESIV;
	} else {
		iv = (const uint8_t *)luaL_checklstring(L, idx, &size);
		if (size < AESGROUP_LEN) {
			memset(group, 0, AESGROUP_LEN * sizeof(uint8_t));
			memcpy(group, iv, size);
			return (const uint32_t *)group;
		} else {
			return (const uint32_t *)iv;
		}
	}
}

static inline int
aes_do(lua_State *L, aes_func_t func)
{
	int data_type;
	uint8_t *keyptr;
	const uint32_t *ivptr;
	size_t key_size, key_bits;
	const uint8_t *key_text;
	uint8_t keybuf[AES256_KEY];
	uint8_t ivbuf[AESGROUP_LEN];
	key_text = (uint8_t *)luaL_checklstring(L, 1, &key_size);
	keyptr = keybuf;
	if (key_size > AES256_KEY) {
		sha256_context ctx;
		sha256_starts(&ctx);
		sha256_update(&ctx, key_text, key_size);
		sha256_finish(&ctx, keybuf);
		key_bits = 256;
	} else {
		switch (key_size) {
		case 16: //aes-128
		case 24: //aes-192
		case 32: //aes-256
			memcpy(keybuf, key_text, key_size);
			break;
		default:
			memset(keybuf, 0, sizeof(keybuf));
			memcpy(keybuf, key_text, key_size);
			key_size = AES256_KEY;
			break;
		}
		key_bits = key_size * 8;
	}
	data_type = lua_type(L, 2);
	if (data_type == LUA_TSTRING) {
		uint8_t *recv;
		size_t datasz;
		const uint8_t *data;
		data = (const uint8_t *)luaL_checklstring(L, 2, &datasz);
		ivptr = aes_getiv(L, 3, ivbuf);
		recv = aes_getbuffer(L, datasz);
		func(keyptr, key_bits, ivptr, data, recv, datasz);
		lua_pushlstring(L, (char *)recv, datasz);
		return 1;
	} else if (data_type == LUA_TLIGHTUSERDATA) {
		uint8_t *data = (uint8_t *)lua_touserdata(L, 2);
		size_t data_sz = luaL_checkinteger(L, 3);
		ivptr = aes_getiv(L, 4, ivbuf);
		func(keyptr, key_bits, ivptr, data, data, data_sz);
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

static unsigned int
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
	unsigned int n = 0;
	switch (sz) {
	default:
		/* fall through */
	case 3:
		n |= (uint8_t)src[2];
		/* fall through */
	case 2:
		n |= (uint8_t)src[1] << 8;
		/* fall through */
	case 1:
		n |= (uint8_t)src[0] << 16;
		break;
	case 0:
		assert(0);
		break;
	}
	dst[3] = dict(n & 0x3f);
	dst[2] = dict((n >> 6) & 0x3f);
	dst[1] = dict((n >> 12) & 0x3f);
	dst[0] = dict((n >> 18) & 0x3f);
}

static void
chartonum(char *dst, size_t sz, const char *src)
{
	unsigned int n = 0;
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
		return luaL_error(L, "base64decode invalid param");
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

static inline void
setfuncs_withbuffer(lua_State *L, luaL_Reg tbl[])
{
	while (tbl->name) {
		lua_newuserdata(L, AESBUFF_LEN);
		lua_pushcclosure(L, tbl->func, 1);
		lua_setfield(L, -2, tbl->name);
		++tbl;
	}
	return ;
}

int
luaopen_sys_crypto(lua_State *L)
{
	luaL_Reg tbl[] = {
		{"md5", lmd5},
		{"sha1", lsha1},
		{"hmac", lhmac_sha1},
		{"randomkey", lrandomkey},
		{"aesencode", laesencode},
		{"aesdecode", laesdecode},
		{"base64encode", lbase64encode},
		{"base64decode", lbase64decode},
		{NULL, NULL},
	};
	luaL_Reg tbl_b[] = {
		{"aesencode", laesencode},
		{"aesdecode", laesdecode},
		{NULL, NULL},
	};
	luaL_checkversion(L);
	luaL_newlib(L, tbl);
	setfuncs_withbuffer(L, tbl_b);
	return 1;
}
