#ifndef __LUA_BUFFER_EX_H__
#define __LUA_BUFFER_EX_H__

#include <stdint.h>
#include <lua.h>
#include <lauxlib.h>

#include "lenenc.h"

static inline void luaL_addint2(luaL_Buffer *b, lua_Unsigned v)
{
	uint8_t *ptr = (uint8_t *)luaL_prepbuffsize(b, 2);
	luaL_addsize(b, 2);
	ptr[0] = v & 0xff;
	ptr[1] = (v >> 8) & 0xff;
}

static inline void luaL_addint4(luaL_Buffer *b, lua_Unsigned v)
{
	uint8_t *ptr = (uint8_t *)luaL_prepbuffsize(b, 4);
	luaL_addsize(b, 4);
	ptr[0] = v & 0xff;
	ptr[1] = (v >> 8) & 0xff;
	ptr[2] = (v >> 16) & 0xff;
	ptr[3] = (v >> 24) & 0xff;
}

static inline void luaL_addint8(luaL_Buffer *b, lua_Unsigned v)
{
	uint8_t *ptr = (uint8_t *)luaL_prepbuffsize(b, 8);
	luaL_addsize(b, 8);
	ptr[0] = v & 0xff;
	ptr[1] = (v >> 8) & 0xff;
	ptr[2] = (v >> 16) & 0xff;
	ptr[3] = (v >> 24) & 0xff;
	ptr[4] = (v >> 32) & 0xff;
	ptr[5] = (v >> 40) & 0xff;
	ptr[6] = (v >> 48) & 0xff;
	ptr[7] = (v >> 56) & 0xff;
}

static inline void luaL_adddouble(luaL_Buffer *b, double v)
{
	union {
		double d;
		uint64_t i;
	} u;
	u.d = v;
	uint8_t *ptr = (uint8_t *)luaL_prepbuffsize(b, 8);
	luaL_addsize(b, 8);
	ptr[0] = u.i & 0xff;
	ptr[1] = (u.i >> 8) & 0xff;
	ptr[2] = (u.i >> 16) & 0xff;
	ptr[3] = (u.i >> 24) & 0xff;
	ptr[4] = (u.i >> 32) & 0xff;
	ptr[5] = (u.i >> 40) & 0xff;
	ptr[6] = (u.i >> 48) & 0xff;
	ptr[7] = (u.i >> 56) & 0xff;
}

static inline void luaL_addlenenc_string(luaL_Buffer *b, int stk)
{
	const char *str;
	size_t str_len;
	str = luaL_checklstring(b->L, stk, &str_len);
	// lenenc string length
	if (str_len < 251) {
		luaL_addchar(b, str_len);
	} else if (str_len < (1 << 16)) {
		luaL_addchar(b, LENENC_2BYTES);
		luaL_addchar(b, str_len & 0xff);
		luaL_addchar(b, (str_len >> 8) & 0xff);
	} else if (str_len < (1 << 24)) {
		luaL_addchar(b, LENENC_3BYTES);
		luaL_addchar(b, str_len & 0xff);
		luaL_addchar(b, (str_len >> 8) & 0xff);
		luaL_addchar(b, (str_len >> 16) & 0xff);
	} else {
		luaL_addchar(b, LENENC_8BYTES);
		luaL_addchar(b, str_len & 0xff);
		luaL_addchar(b, (str_len >> 8) & 0xff);
		luaL_addchar(b, (str_len >> 16) & 0xff);
		luaL_addchar(b, (str_len >> 24) & 0xff);
		luaL_addchar(b, (str_len >> 32) & 0xff);
		luaL_addchar(b, (str_len >> 40) & 0xff);
		luaL_addchar(b, (str_len >> 48) & 0xff);
		luaL_addchar(b, (str_len >> 56) & 0xff);
	}
	// append string
	luaL_addlstring(b, str, str_len);
}

#endif
