#include <assert.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <strings.h>
#include <lua.h>
#include <lauxlib.h>

#include "md5.h"
#include "aes.h"
#include "sha256.h"
#include "lsha1.h"

#ifdef __WIN32
#define random() rand()
#endif

char num_to_char[] = "0123456789abcdef";

static int lmd5(lua_State *L)
{
	size_t sz;
	uint8_t out[16];
	char str[2 * 16];
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

static int lxor(lua_State *L)
{
	size_t i;
	const char *key;
	size_t key_len;
	const char *dat;
	size_t dat_len;
	luaL_Buffer b;
	key = luaL_checklstring(L, 1, &key_len);
	dat = luaL_checklstring(L, 2, &dat_len);
	luaL_buffinitsize(L, &b, dat_len);
	luaL_argcheck(L, key_len > 0, 1, "crypto.xor key can't be empty");
	for (i = 0; i < dat_len; i++) {
		uint8_t k = key[i % key_len];
		uint8_t c = (uint8_t)dat[i] ^ k;
		luaL_addchar(&b, c);
	}
	luaL_pushresult(&b);
	return 1;
}

static int lsha256(lua_State *L)
{
	size_t i, j, sz;
	sha256_context ctx;
	uint8_t keybuf[256 / 8];
	char strbuf[256 / 8 * 2];
	const char *str = luaL_checklstring(L, 1, &sz);
	int binary = luaL_optinteger(L, 2, 0);
	sha256_starts(&ctx);
	sha256_update(&ctx, (const uint8_t *)str, sz);
	sha256_finish(&ctx, keybuf);
	if (binary == 0) {
		for (i = 0, j = 0; i < sizeof(keybuf) / sizeof(keybuf[0]);
		     i++) {
			uint8_t n = keybuf[i];
			strbuf[j++] = num_to_char[n >> 4];
			strbuf[j++] = num_to_char[n & 0xf];
		}
		lua_pushlstring(L, strbuf, j);
	} else {
		lua_pushlstring(L, (char *)keybuf, sizeof(keybuf));
	}
	return 1;
}

static int lrandomkey(lua_State *L)
{
	int i;
	luaL_Buffer b;
	int n = luaL_checkinteger(L, 1);
	luaL_buffinitsize(L, &b, n);
	for (i = 0; i < n; i++)
		luaL_addchar(&b, random() % 26 + 'a');
	luaL_pushresult(&b);
	return 1;
}

#define AESBUFF_LEN (512)
#define AESKEY_LEN (32)
#define AES128_KEY (16)
#define AES192_KEY (24)
#define AES256_KEY (32)
#define AESGROUP_LEN (16)
#define AESGROUP_LEN_POWER (4)
#define AESIV ((uint32_t *)("!*^$~)_+=-)(87^$#Dfhjklmnb<>,k./;KJl"))

static void aes_encode(const uint8_t *key, int keybits, const uint32_t *iv,
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
		return;
	//OFB
	aes_encrypt(&ctx, (uint8_t *)iv, tail);
	for (i = 0; i < last; i++)
		dst[i] = src[i] ^ tail[i];
	return;
}

static void aes_decode(const uint8_t *key, int keybits, const uint32_t *iv,
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
		return;
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
	return;
}

typedef void (*aes_func_t)(const uint8_t *key, int keybits, const uint32_t *iv,
			   const uint8_t *src, uint8_t *dst, int sz);

static inline uint8_t *aes_getbuffer(lua_State *L, size_t need)
{
	uint8_t *data;
	int idx = lua_upvalueindex(1);
	size_t total = lua_rawlen(L, idx);
	if (total < need) {
		data = lua_newuserdatauv(L, need, 0);
		lua_replace(L, idx);
	} else {
		data = lua_touserdata(L, idx);
	}
	return data;
}

static inline const uint32_t *aes_getiv(lua_State *L, int idx,
					uint8_t group[AESGROUP_LEN])
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

static inline int aes_do(lua_State *L, aes_func_t func)
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

static int laesencode(lua_State *L)
{
	return aes_do(L, aes_encode);
}

static int laesdecode(lua_State *L)
{
	return aes_do(L, aes_decode);
}

static inline unsigned int undict(int ch)
{
	int v;
	if (ch == '+' || ch == '-')
		v = 62;
	else if (ch == '/' || ch == '_')
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

static int lbase64encode(lua_State *L)
{
	size_t sz;
	int i, j;
	unsigned int n;
	int need, urlsafe;
	char *ptr;
	const char *dict;
	const uint8_t *dat;
	luaL_Buffer lbuf;
	dat = (const uint8_t *)luaL_checklstring(L, 1, &sz);
	dict = lua_tostring(L, 2);
	if (dict && strcasecmp(dict, "url") == 0) {
		urlsafe = 1;
		dict = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
	} else {
		urlsafe = 0;
		dict = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
	}
	need = (sz + 2) / 3 * 4;
	ptr = luaL_buffinitsize(L, &lbuf, need);
	for (i = 0, j = 0; i < (int)sz - 2; i += 3, j += 4) {
		n = (dat[i + 0] << 16) | (dat[i + 1] << 8) | dat[i + 2];
		ptr[j + 0] = dict[(n >> 18) & 0x3f];
		ptr[j + 1] = dict[(n >> 12) & 0x3f];
		ptr[j + 2] = dict[(n >> 6) & 0x3f];
		ptr[j + 3] = dict[n & 0x3f];
	}
	switch (sz - i) {
	case 1:
		n = dat[i] << 16;
		ptr[j++] = dict[n >> 18];
		ptr[j++] = dict[(n >> 12) & 0x3f];
		if (urlsafe == 0) {
			ptr[j++] = '=';
			ptr[j++] = '=';
		}
		break;
	case 2:
		n = dat[i] << 16 | dat[i + 1] << 8;
		ptr[j++] = dict[n >> 18];
		ptr[j++] = dict[(n >> 12) & 0x3f];
		ptr[j++] = dict[(n >> 6) & 0x3f];
		if (urlsafe == 0)
			ptr[j++] = '=';
		break;
	}
	luaL_pushresultsize(&lbuf, j);
	return 1;
}

static int lbase64decode(lua_State *L)
{
	size_t sz;
	char *dst;
	const char *dat;
	int i = 0, j = 0;
	luaL_Buffer lbuf;
	dat = luaL_checklstring(L, 1, &sz);
	if (sz == 0) {
		lua_pushliteral(L, "");
		return 1;
	}
	dst = luaL_buffinitsize(L, &lbuf, (sz + 3) / 4 * 3);
	while (i < (int)sz) {
		int k;
		unsigned int n;
		k = ((i + 4) > (int)sz ? (int)sz : (i + 4)) - 1;
		while (k >= i && dat[k] == '=')
			--k;
		switch (k - i + 1) {
		case 4:
			n = undict(dat[i + 3]) | undict(dat[i + 2]) << 6 |
			    undict(dat[i + 1]) << 12 | undict(dat[i + 0]) << 18;
			dst[j++] = (n >> 16) & 0xff;
			dst[j++] = (n >> 8) & 0xff;
			dst[j++] = n & 0xff;
			break;
		case 3:
			n = undict(dat[i + 2]) << 6 | undict(dat[i + 1]) << 12 |
			    undict(dat[i + 0]) << 18;
			dst[j++] = (n >> 16) & 0xff;
			dst[j++] = (n >> 8) & 0xff;
			break;
		case 2:
			n = undict(dat[i + 1]) << 12 | undict(dat[i + 0]) << 18;
			dst[j++] = (n >> 16) & 0xff;
			break;

		case 1:
			n = undict(dat[i + 0]) << 18;
			dst[j++] = (n >> 16) & 0xff;
			break;
		}
		i += 4;
	}
	luaL_pushresultsize(&lbuf, j);
	return 1;
}

#ifdef USE_OPENSSL
#include <openssl/pem.h>
#include <openssl/err.h>
#include <openssl/evp.h>

static int ldigestsign(lua_State *L)
{
	int ok = 0;
	const EVP_MD *md;
	EVP_MD_CTX *mdctx;
	BIO *bio;
	EVP_PKEY *pk;
	luaL_Buffer b;
	size_t ksz, dsz, siglen;
	const char *key = luaL_checklstring(L, 1, &ksz);
	const char *dat = luaL_checklstring(L, 2, &dsz);
	const char *hname = luaL_checkstring(L, 3);
	md = EVP_get_digestbyname(hname);
	if (md == NULL)
		return luaL_error(L, "unkonw hash method '%s'", hname);
	bio = BIO_new_mem_buf(key, ksz);
	pk = PEM_read_bio_PrivateKey(bio, NULL, NULL, NULL);
	if (bio != NULL)
		BIO_free(bio);
	luaL_argcheck(L, pk != NULL, 1, "invalid private key in PEM format");
	mdctx = EVP_MD_CTX_create();
	do {
		unsigned char *sig;
		if (EVP_DigestSignInit(mdctx, NULL, md, NULL, pk) != 1)
			break;
		if (EVP_DigestSignUpdate(mdctx, dat, dsz) != 1)
			break;
		if (EVP_DigestSignFinal(mdctx, NULL, &siglen) != 1)
			break;
		sig = (unsigned char *)luaL_buffinitsize(L, &b, siglen);
		if (EVP_DigestSignFinal(mdctx, sig, &siglen) != 1)
			break;
		ok = 1;
		luaL_pushresultsize(&b, siglen);
	} while (0);
	EVP_MD_CTX_destroy(mdctx);
	if (pk != NULL)
		EVP_PKEY_free(pk);
	if (ok != 1) {
		return luaL_error(L, "digest sign error:%s",
				  ERR_error_string(ERR_get_error(), NULL));
	}
	return 1;
}

static int ldigestverify(lua_State *L)
{
	int ok = 0;
	int verifyok = 0;
	BIO *bio;
	EVP_PKEY *pk;
	const EVP_MD *md;
	EVP_MD_CTX *mdctx;
	size_t ksz, dsz, siglen;
	const char *key = luaL_checklstring(L, 1, &ksz);
	const char *dat = luaL_checklstring(L, 2, &dsz);
	const uint8_t *sig = (const uint8_t *)luaL_checklstring(L, 3, &siglen);
	const char *hname = luaL_checkstring(L, 4);
	md = EVP_get_digestbyname(hname);
	if (md == NULL)
		return luaL_error(L, "unkonw hash method '%s'", hname);
	bio = BIO_new_mem_buf(key, ksz);
	pk = PEM_read_bio_PUBKEY(bio, NULL, NULL, NULL);
	if (bio != NULL)
		BIO_free(bio);
	luaL_argcheck(L, pk != NULL, 1, "invalid public key in PEM format");
	mdctx = EVP_MD_CTX_create();
	do {
		if (EVP_DigestVerifyInit(mdctx, NULL, md, NULL, pk) != 1)
			break;
		if (EVP_DigestVerifyUpdate(mdctx, dat, dsz) != 1)
			break;
		switch (EVP_DigestVerifyFinal(mdctx, sig, siglen)) {
		case 1:
			ok = 1;
			verifyok = 1;
			break;
		case 0:
			ok = 1;
			verifyok = 0;
			break;
		default:
			ok = 0;
			verifyok = 0;
			break;
		}
	} while (0);
	EVP_MD_CTX_destroy(mdctx);
	if (pk != NULL)
		EVP_PKEY_free(pk);
	if (ok != 1) {
		return luaL_error(L, "digest verify error:%s",
				  ERR_error_string(ERR_get_error(), NULL));
	}
	lua_pushboolean(L, verifyok);
	return 1;
}

#endif

static inline void setfuncs_withbuffer(lua_State *L, luaL_Reg tbl[])
{
	while (tbl->name) {
		lua_newuserdatauv(L, AESBUFF_LEN, 0);
		lua_pushcclosure(L, tbl->func, 1);
		lua_setfield(L, -2, tbl->name);
		++tbl;
	}
	return;
}

int luaopen_core_crypto(lua_State *L)
{
	luaL_Reg tbl[] = {
		{ "xor",          lxor          },
		{ "md5",          lmd5          },
		{ "sha1",         lsha1         },
		{ "sha256",       lsha256       },
		{ "hmac",         lhmac_sha1    },
		{ "randomkey",    lrandomkey    },
		{ "aesencode",    laesencode    },
		{ "aesdecode",    laesdecode    },
		{ "base64encode", lbase64encode },
		{ "base64decode", lbase64decode },
#ifdef USE_OPENSSL
		{ "digestsign",   ldigestsign   },
		{ "digestverify", ldigestverify },
#endif
		{ NULL,           NULL          },
	};
	luaL_Reg tbl_b[] = {
		{ "aesencode", laesencode },
		{ "aesdecode", laesdecode },
		{ NULL,        NULL       },
	};
	luaL_checkversion(L);
	luaL_newlib(L, tbl);
	setfuncs_withbuffer(L, tbl_b);

#ifdef USE_OPENSSL
#if OPENSSL_VERSION_NUMBER < 0x10100000L
	OpenSSL_add_all_digests();
#endif
#endif
	return 1;
}
