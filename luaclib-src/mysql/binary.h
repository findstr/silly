#ifndef __BINARY_H__
#define __BINARY_H__

#include <stdint.h>
#include <stddef.h>
#include <lua.h>
#include <lauxlib.h>

#include "lenenc.h"

struct binary {
	lua_State *L;
	const char *prompt;
	const uint8_t *data;
	size_t len;
	size_t pos;
	size_t start;
};

static inline int binary_error(struct binary *chk, const char *err)
{
	// print the chunk detail
	luaL_Buffer buf;
	luaL_buffinit(chk->L, &buf);
	for (size_t i = chk->start; i < chk->len; i++) {
		char tmp[3];
		snprintf(tmp, sizeof(tmp), "%02x", chk->data[i]);
		luaL_addlstring(&buf, tmp, 2);
	}
	luaL_pushresult(&buf);
	return luaL_error(chk->L, "%s error chunk:%s pos:%d err:%s", chk->prompt,
			  lua_tostring(chk->L, -1), chk->pos, err);
}


// 1 byte
static inline lua_Integer binary_read_uint8(struct binary *chk)
{
	if (chk->pos >= chk->len) {
		return binary_error(chk, "read_uint8 pos out of range");
	}
	return chk->data[chk->pos++];
}

static inline lua_Integer binary_read_int8(struct binary *chk)
{
	lua_Integer v = binary_read_uint8(chk);
	return (int8_t)v;
}

// 2 bytes
static inline lua_Integer binary_read_uint16le(struct binary *chk)
{
	if (chk->pos + 2 > chk->len) {
		return binary_error(chk, "read_uint16le pos out of range");
	}
	const uint8_t *ptr = chk->data + chk->pos;
	chk->pos += 2;
	return (uint64_t)ptr[0] | ((uint64_t)ptr[1] << 8);
}

static inline lua_Integer binary_read_int16le(struct binary *chk)
{
	lua_Integer v = binary_read_uint16le(chk);
	return (int16_t)v;
}

// 3 bytes
static inline lua_Integer binary_read_uint24le(struct binary *chk)
{
	if (chk->pos + 3 > chk->len) {
		return binary_error(chk, "read_uint24le pos out of range");
	}
	const uint8_t *ptr = chk->data + chk->pos;
	chk->pos += 3;
	return (uint64_t)ptr[0] | ((uint64_t)ptr[1] << 8) |
	       ((uint64_t)ptr[2] << 16);
}

static inline lua_Integer binary_read_int24le(struct binary *chk)
{
	lua_Integer v = binary_read_uint24le(chk);
	lua_Unsigned u = (lua_Unsigned)v & 0xffffff;
	if (u & 0x800000) { // negative, sign extend
		u |= 0xff000000;
	}
	return (int32_t)u;
}

static inline lua_Integer binary_read_uint32le(struct binary *chk)
{
	if (chk->pos + 4 > chk->len) {
		return binary_error(chk, "read_uint32le pos out of range");
	}
	const uint8_t *ptr = chk->data + chk->pos;
	chk->pos += 4;
	return (lua_Unsigned)ptr[0] | ((lua_Unsigned)ptr[1] << 8) |
	       ((lua_Unsigned)ptr[2] << 16) | ((lua_Unsigned)ptr[3] << 24);
}

static inline lua_Integer binary_read_int32le(struct binary *chk)
{
	lua_Integer v = binary_read_uint32le(chk);
	return (int32_t)v;
}

// 8 bytes
static inline lua_Integer binary_read_uint64le(struct binary *chk)
{
	if (chk->pos + 8 > chk->len) {
		return binary_error(chk, "read_uint64le pos out of range");
	}
	const uint8_t *ptr = chk->data + chk->pos;
	chk->pos += 8;
	return (uint64_t)ptr[0] | ((uint64_t)ptr[1] << 8) |
	       ((uint64_t)ptr[2] << 16) | ((uint64_t)ptr[3] << 24) |
	       ((uint64_t)ptr[4] << 32) | ((uint64_t)ptr[5] << 40) |
	       ((uint64_t)ptr[6] << 48) | ((uint64_t)ptr[7] << 56);
}

static inline lua_Integer binary_read_int64le(struct binary *chk)
{
	lua_Integer v = binary_read_uint64le(chk);
	return (int64_t)v;
}

static inline lua_Number binary_read_float32le(struct binary *chk)
{
	union {
		uint32_t i;
		float f;
	} u;
	u.i = binary_read_uint32le(chk);
	return u.f;
}

static inline lua_Number binary_read_float64le(struct binary *chk)
{
	union {
		uint64_t i;
		double d;
	} u;
	u.i = binary_read_uint64le(chk);
	return u.d;
}

/// binary_check(string)
static inline void binary_check(lua_State *L, struct binary *chk,
	const char *prompt, int stk)
{
	size_t len;
	chk->L = L;
	chk->prompt = prompt;
	chk->data = (const uint8_t *)luaL_checklstring(L, stk, &len);
	chk->len = len;
	chk->pos = 0;
	chk->start = 0;
}

static inline lua_Integer binary_read_lenenc_with_null(struct binary *chk, int *is_null)
{
	unsigned char first;
	if (is_null)
		*is_null = 0;
	if (chk->pos >= chk->len) {
		return binary_error(chk, "read_lenenc pos out of range");
	}
	first = chk->data[chk->pos++];
	if (first < LENENC_NULL) {
		return first;
	}
	switch (first) {
	case LENENC_NULL:
		if (is_null)
			*is_null = 1;
		return 0;
	case LENENC_2BYTES: // 2 bytes
		return binary_read_uint16le(chk);
	case LENENC_3BYTES: // 3 bytes
		return binary_read_uint24le(chk);
	case LENENC_8BYTES: // 8 bytes
		return binary_read_uint64le(chk);
	default:
		return binary_error(chk, "invalid lenenc");
	}
}

static inline lua_Integer binary_read_lenenc(struct binary *chk)
{
	int is_null;
	lua_Integer v = binary_read_lenenc_with_null(chk, &is_null);
	if (is_null) {
		return binary_error(chk, "read_lenenc is null");
	}
	return v;
}

#endif
