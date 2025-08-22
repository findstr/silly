#include <assert.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <strings.h>
#include <lua.h>
#include <lauxlib.h>

static inline unsigned int undict(int ch)
{
	if (ch == '+' || ch == '-')
		return 62;
	if (ch == '/' || ch == '_')
		return 63;
	if (ch >= 'A' && ch <= 'Z')
		return ch - 'A';
	if (ch >= 'a' && ch <= 'z')
		return ch - 'a' + 26;
	if (ch >= '0' && ch <= '9')
		return ch - '0' + 52;
	return 0; // '=' or invalid character
}

static int encodex(lua_State *L, int urlsafe)
{
	size_t sz;
	int i, j;
	unsigned int n;
	int need;
	char *ptr;
	const char *dict;
	const uint8_t *dat;
	luaL_Buffer lbuf;
	dat = (const uint8_t *)luaL_checklstring(L, 1, &sz);
	if (urlsafe) {
		dict = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
	} else {
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
		if (!urlsafe) {
			ptr[j++] = '=';
			ptr[j++] = '=';
		}
		break;
	case 2:
		n = (dat[i] << 16) | (dat[i + 1] << 8);
		ptr[j++] = dict[n >> 18];
		ptr[j++] = dict[(n >> 12) & 0x3f];
		ptr[j++] = dict[(n >> 6) & 0x3f];
		if (!urlsafe)
			ptr[j++] = '=';
		break;
	default:
		break;
	}
	luaL_pushresultsize(&lbuf, j);
	return 1;
}

/// base64.encode(msg)
static int lencode(lua_State *L)
{
	return encodex(L, 0);
}

/// base64.urlsafe_encode(msg)
static int lurlsafe_encode(lua_State *L)
{
	return encodex(L, 1);
}

/// base64.decode(msg)
/// base64.urlsafe_decode(msg)
int ldecode(lua_State *L)
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
			n = (undict(dat[i]) << 18) |
			    (undict(dat[i + 1]) << 12) |
			    (undict(dat[i + 2]) << 6) | undict(dat[i + 3]);
			dst[j++] = (n >> 16) & 0xff;
			dst[j++] = (n >> 8) & 0xff;
			dst[j++] = n & 0xff;
			break;
		case 3:
			n = (undict(dat[i]) << 18) |
			    (undict(dat[i + 1]) << 12) |
			    (undict(dat[i + 2]) << 6);
			dst[j++] = (n >> 16) & 0xff;
			dst[j++] = (n >> 8) & 0xff;
			break;
		case 2:
			n = (undict(dat[i]) << 18) | (undict(dat[i + 1]) << 12);
			dst[j++] = (n >> 16) & 0xff;
			break;
		default:
			break;
		}
		i += 4;
	}
	luaL_pushresultsize(&lbuf, j);
	return 1;
}

int luaopen_core_encoding_base64(lua_State *L)
{
	luaL_Reg tbl[] = {
		{ "encode",         lencode         },
		{ "decode",         ldecode         },
		{ "urlsafe_encode", lurlsafe_encode },
		{ "urlsafe_decode", ldecode         },
		{ NULL,             NULL            },
	};
	luaL_checkversion(L);
	luaL_newlib(L, tbl);
	return 1;
}
