#include <assert.h>
#include <ctype.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <lua.h>
#include <lauxlib.h>

#include "silly.h"
#include "luabuf.h"
#include "luafmt.h"

#define MAX_DEPTH 128
#define NULL_UPVALUE lua_upvalueindex(1)

/* -------------------- encoder -------------------- */

struct encode_state {
	struct luabuf lb;
	const char *error;
};

static int encode_value(struct encode_state *es, int idx, int depth);

static void encode_string(struct encode_state *es, int idx)
{
	size_t len;
	struct luabuf *lb = &es->lb;
	const char *str = lua_tolstring(lb->L, idx, &len);
	const uint8_t *p = (const uint8_t *)str;
	const uint8_t *end = p + len;
	luabuf_addchar(lb, '"');
	while (p < end) {
		uint8_t ch = *p;
		switch (ch) {
		case '"':
			luabuf_addlstring(lb, "\\\"", 2);
			break;
		case '\\':
			luabuf_addlstring(lb, "\\\\", 2);
			break;
		case '\b':
			luabuf_addlstring(lb, "\\b", 2);
			break;
		case '\f':
			luabuf_addlstring(lb, "\\f", 2);
			break;
		case '\n':
			luabuf_addlstring(lb, "\\n", 2);
			break;
		case '\r':
			luabuf_addlstring(lb, "\\r", 2);
			break;
		case '\t':
			luabuf_addlstring(lb, "\\t", 2);
			break;
		default:
			if (ch < 0x20) {
				char esc[7];
				snprintf(esc, sizeof(esc), "\\u%04x", ch);
				luabuf_addlstring(lb, esc, 6);
			} else {
				luabuf_addchar(lb, ch);
			}
			break;
		}
		p++;
	}
	luabuf_addchar(lb, '"');
}

/* Check if double is actually an integer (e.g., 42.0) */
static int is_integer_double(double d, long long *out)
{
	double rounded = nearbyint(d);
	if (d != rounded)
		return 0;
	if (d >= (double)LLONG_MIN && d < (double)LLONG_MAX) {
		*out = (long long)d;
		return 1;
	}
	return 0;
}

static int encode_number(struct encode_state *es, int idx)
{
	char tmp[32];
	int len;
	struct luabuf *lb = &es->lb;
	lua_State *L = lb->L;

	if (lua_isinteger(L, idx)) {
		lua_Integer n = lua_tointeger(L, idx);
		len = luafmt_int64(tmp, (int64_t)n);
	} else {
		lua_Number n = lua_tonumber(L, idx);
		long long ivalue;

		if (unlikely(isinf(n) || isnan(n))) {
			es->error = "NaN or Infinity not allowed";
			return -1;
		}

		/* Fast path: floats that are actually integers (e.g., 42.0, 3.0) */
		if (is_integer_double((double)n, &ivalue)) {
			len = luafmt_int64(tmp, ivalue);
		} else {
			/* Slow path: real float - use snprintf (like Lua does) */
			char *dp;
			len = snprintf(tmp, sizeof(tmp), "%.14g", (double)n);
			/* fix locale decimal separator (e.g. ',' in de_DE) */
			dp = strchr(tmp, ',');
			if (dp)
				*dp = '.';
		}
	}
	luabuf_addlstring(lb, tmp, len);
	return 0;
}

static int encode_array(struct encode_state *es, int idx, int depth)
{
	lua_Integer i;
	lua_Integer arrlen = luaL_len(es->lb.L, idx);
	luabuf_addchar(&es->lb, '[');
	for (i = 1; i <= arrlen; i++) {
		if (i > 1)
			luabuf_addchar(&es->lb, ',');
		lua_rawgeti(es->lb.L, idx, i);
		if (unlikely(encode_value(es, lua_gettop(es->lb.L), depth + 1) < 0)) {
			lua_pop(es->lb.L, 1);
			return -1;
		}
		lua_pop(es->lb.L, 1);
	}
	luabuf_addchar(&es->lb, ']');
	return 0;
}

static int encode_object(struct encode_state *es, int idx, int depth)
{
	luabuf_addchar(&es->lb, '{');
	lua_pushnil(es->lb.L);
	while (lua_next(es->lb.L, idx) != 0) {
		if (unlikely(lua_type(es->lb.L, -2) != LUA_TSTRING)) {
			lua_pop(es->lb.L, 2); /* pop key + value */
			es->error = "object key must be string";
			return -1;
		}
		encode_string(es, lua_gettop(es->lb.L) - 1);
		luabuf_addchar(&es->lb, ':');
		if (unlikely(encode_value(es, lua_gettop(es->lb.L), depth + 1) < 0)) {
			lua_pop(es->lb.L, 2); /* pop key + value */
			return -1;
		}
		lua_pop(es->lb.L, 1); /* pop value, keep key */
		luabuf_addchar(&es->lb, ',');
	}
	luabuf_backspace(&es->lb, 1); /* remove trailing comma if any */
	luabuf_addchar(&es->lb, '}');
	return 0;
}

static int encode_table(struct encode_state *es, int idx, int depth)
{
	int is_array;
	struct luabuf *lb = &es->lb;
	lua_State *L = lb->L;
	if (unlikely(depth > MAX_DEPTH)) {
		es->error = "nesting too deep";
		return -1;
	}
	/* normalize idx to absolute */
	idx = lua_absindex(L, idx);
	/* check for json.null (upvalue comparison) */
	if (lua_rawequal(L, idx, NULL_UPVALUE)) {
		luabuf_addlstring(lb, "null", 4);
		return 0;
	}
	luaL_checkstack(L, depth + LUA_MINSTACK, "too many nested tables");
	/* detect array: has element at index 1, or empty table */
	lua_rawgeti(L, idx, 1);
	is_array = !lua_isnil(L, -1);
	lua_pop(L, 1);
	if (!is_array) {
		/* check if table is empty (object with no keys = empty array) */
		lua_pushnil(L);
		if (lua_next(L, idx) == 0) {
			is_array = 1; /* empty table → [] */
		} else {
			lua_pop(L, 2);
		}
	}
	if (is_array)
		return encode_array(es, idx, depth);
	return encode_object(es, idx, depth);
}

static int encode_value(struct encode_state *es, int idx, int depth)
{
	struct luabuf *lb = &es->lb;
	lua_State *L = lb->L;
	int t = lua_type(L, idx);
	switch (t) {
	case LUA_TSTRING:
		encode_string(es, idx);
		return 0;
	case LUA_TNUMBER:
		return encode_number(es, idx);
	case LUA_TBOOLEAN:
		if (lua_toboolean(L, idx))
			luabuf_addlstring(lb, "true", 4);
		else
			luabuf_addlstring(lb, "false", 5);
		return 0;
	case LUA_TTABLE:
		return encode_table(es, idx, depth);
	case LUA_TNIL:
		luabuf_addlstring(lb, "null", 4);
		return 0;
	default:
		es->error = "unsupported type";
		return -1;
	}
}

/// json.encode(obj) — upvalue 1 is json.null
static int lencode(lua_State *L)
{
	struct encode_state es;
	luaL_checkany(L, 1);
	es.error = NULL;
	luabuf_init(&es.lb, L);
	if (unlikely(encode_value(&es, 1, 0) < 0)) {
		luabuf_free(&es.lb);
		lua_pushnil(L);
		lua_pushstring(L, es.error);
		return 2;
	}
	luabuf_pushresult(&es.lb);
	return 1;
}

/* -------------------- decoder -------------------- */

struct decode_state {
	lua_State *L;
	const char *ptr;
	const char *end;
	int null_idx; /* absolute stack index of json.null */
};

static inline void skip_space(struct decode_state *s)
{
	while (s->ptr < s->end) {
		char ch = *s->ptr;
		if (ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r')
			s->ptr++;
		else
			break;
	}
}

static inline int hex_digit(char ch)
{
	if (ch >= '0' && ch <= '9')
		return ch - '0';
	if (ch >= 'a' && ch <= 'f')
		return ch - 'a' + 10;
	if (ch >= 'A' && ch <= 'F')
		return ch - 'A' + 10;
	return -1;
}

static int parse_hex4(const char *p, uint32_t *out)
{
	int i;
	uint32_t val = 0;
	for (i = 0; i < 4; i++) {
		int d = hex_digit(p[i]);
		if (d < 0)
			return -1;
		val = (val << 4) | d;
	}
	*out = val;
	return 0;
}

static int utf8_encode(uint32_t cp, char *out)
{
	if (cp <= 0x7F) {
		out[0] = (char)cp;
		return 1;
	} else if (cp <= 0x7FF) {
		out[0] = (char)(0xC0 | (cp >> 6));
		out[1] = (char)(0x80 | (cp & 0x3F));
		return 2;
	} else if (cp <= 0xFFFF) {
		out[0] = (char)(0xE0 | (cp >> 12));
		out[1] = (char)(0x80 | ((cp >> 6) & 0x3F));
		out[2] = (char)(0x80 | (cp & 0x3F));
		return 3;
	} else if (cp <= 0x10FFFF) {
		out[0] = (char)(0xF0 | (cp >> 18));
		out[1] = (char)(0x80 | ((cp >> 12) & 0x3F));
		out[2] = (char)(0x80 | ((cp >> 6) & 0x3F));
		out[3] = (char)(0x80 | (cp & 0x3F));
		return 4;
	}
	return 0;
}

static int decode_value(struct decode_state *s);

static int decode_string(struct decode_state *s)
{
	lua_State *L = s->L;
	luaL_Buffer buf;
	luaL_buffinit(L, &buf);
	s->ptr++; /* skip opening '"' */
	while (s->ptr < s->end) {
		char ch = *s->ptr;
		if (ch == '"') {
			s->ptr++;
			luaL_pushresult(&buf);
			return 0;
		}
		if (ch == '\\') {
			s->ptr++;
			if (s->ptr >= s->end)
				return -1;
			ch = *s->ptr;
			switch (ch) {
			case '"':
				luaL_addchar(&buf, '"');
				break;
			case '\\':
				luaL_addchar(&buf, '\\');
				break;
			case '/':
				luaL_addchar(&buf, '/');
				break;
			case 'b':
				luaL_addchar(&buf, '\b');
				break;
			case 'f':
				luaL_addchar(&buf, '\f');
				break;
			case 'n':
				luaL_addchar(&buf, '\n');
				break;
			case 'r':
				luaL_addchar(&buf, '\r');
				break;
			case 't':
				luaL_addchar(&buf, '\t');
				break;
			case 'u': {
				uint32_t cp;
				char u8[4];
				int u8len;
				s->ptr++;
				if (s->ptr + 4 > s->end)
					return -1;
				if (parse_hex4(s->ptr, &cp) < 0)
					return -1;
				s->ptr += 4;
				/* surrogate pair */
				if (cp >= 0xD800 && cp <= 0xDBFF) {
					uint32_t lo;
					if (s->ptr + 6 > s->end ||
					    s->ptr[0] != '\\' ||
					    s->ptr[1] != 'u')
						return -1;
					s->ptr += 2;
					if (parse_hex4(s->ptr, &lo) < 0)
						return -1;
					s->ptr += 4;
					if (lo < 0xDC00 || lo > 0xDFFF)
						return -1;
					cp = 0x10000 +
					     ((cp - 0xD800) << 10) +
					     (lo - 0xDC00);
				} else if (cp >= 0xDC00 && cp <= 0xDFFF) {
					return -1; /* lone low surrogate */
				}
				u8len = utf8_encode(cp, u8);
				if (u8len == 0)
					return -1;
				luaL_addlstring(&buf, u8, u8len);
				continue; /* skip s->ptr++ at bottom */
			}
			default:
				return -1; /* invalid escape */
			}
			s->ptr++;
		} else if ((uint8_t)ch < 0x20) {
			return -1; /* unescaped control character */
		} else {
			luaL_addchar(&buf, ch);
			s->ptr++;
		}
	}
	return -1; /* unterminated string */
}

static int decode_number(struct decode_state *s)
{
	lua_State *L = s->L;
	const char *start = s->ptr;
	int is_float = 0;
	char *numend;
	if (s->ptr < s->end && *s->ptr == '-')
		s->ptr++;
	if (s->ptr >= s->end || !isdigit((uint8_t)*s->ptr))
		return -1;
	if (*s->ptr == '0') {
		s->ptr++;
		if (s->ptr < s->end && isdigit((uint8_t)*s->ptr))
			return -1;
	} else {
		while (s->ptr < s->end && isdigit((uint8_t)*s->ptr))
			s->ptr++;
	}
	if (s->ptr < s->end && *s->ptr == '.') {
		is_float = 1;
		s->ptr++;
		if (s->ptr >= s->end || !isdigit((uint8_t)*s->ptr))
			return -1;
		while (s->ptr < s->end && isdigit((uint8_t)*s->ptr))
			s->ptr++;
	}
	if (s->ptr < s->end && (*s->ptr == 'e' || *s->ptr == 'E')) {
		is_float = 1;
		s->ptr++;
		if (s->ptr < s->end && (*s->ptr == '+' || *s->ptr == '-'))
			s->ptr++;
		if (s->ptr >= s->end || !isdigit((uint8_t)*s->ptr))
			return -1;
		while (s->ptr < s->end && isdigit((uint8_t)*s->ptr))
			s->ptr++;
	}
	if (is_float) {
		double d = strtod(start, &numend);
		lua_pushnumber(L, d);
	} else {
		long long n = strtoll(start, &numend, 10);
		if (n >= LUA_MININTEGER && n <= LUA_MAXINTEGER)
			lua_pushinteger(L, (lua_Integer)n);
		else
			lua_pushnumber(L, (lua_Number)strtod(start, &numend));
	}
	return 0;
}

static int decode_object(struct decode_state *s)
{
	lua_State *L = s->L;
	s->ptr++; /* skip '{' */
	lua_newtable(L);
	skip_space(s);
	if (s->ptr < s->end && *s->ptr == '}') {
		s->ptr++;
		return 0;
	}
	for (;;) {
		skip_space(s);
		if (s->ptr >= s->end || *s->ptr != '"')
			return -1;
		if (decode_string(s) < 0)
			return -1;
		skip_space(s);
		if (s->ptr >= s->end || *s->ptr != ':')
			return -1;
		s->ptr++;
		if (decode_value(s) < 0) {
			lua_pop(L, 1); /* pop key */
			return -1;
		}
		lua_rawset(L, -3);
		skip_space(s);
		if (s->ptr >= s->end)
			return -1;
		if (*s->ptr == '}') {
			s->ptr++;
			return 0;
		}
		if (*s->ptr != ',')
			return -1;
		s->ptr++;
	}
}

static int decode_array(struct decode_state *s)
{
	lua_State *L = s->L;
	int i = 1;
	s->ptr++; /* skip '[' */
	lua_newtable(L);
	skip_space(s);
	if (s->ptr < s->end && *s->ptr == ']') {
		s->ptr++;
		return 0;
	}
	for (;;) {
		if (decode_value(s) < 0)
			return -1;
		lua_rawseti(L, -2, i++);
		skip_space(s);
		if (s->ptr >= s->end)
			return -1;
		if (*s->ptr == ']') {
			s->ptr++;
			return 0;
		}
		if (*s->ptr != ',')
			return -1;
		s->ptr++;
	}
}

static int decode_literal(struct decode_state *s, const char *lit, int len)
{
	if (s->ptr + len > s->end)
		return -1;
	if (memcmp(s->ptr, lit, len) != 0)
		return -1;
	s->ptr += len;
	return 0;
}

static int decode_value(struct decode_state *s)
{
	lua_State *L = s->L;
	skip_space(s);
	if (s->ptr >= s->end)
		return -1;
	switch (*s->ptr) {
	case '"':
		return decode_string(s);
	case '{':
		return decode_object(s);
	case '[':
		return decode_array(s);
	case 't':
		if (decode_literal(s, "true", 4) < 0)
			return -1;
		lua_pushboolean(L, 1);
		return 0;
	case 'f':
		if (decode_literal(s, "false", 5) < 0)
			return -1;
		lua_pushboolean(L, 0);
		return 0;
	case 'n':
		if (decode_literal(s, "null", 4) < 0)
			return -1;
		lua_pushvalue(L, s->null_idx);
		return 0;
	default:
		if (*s->ptr == '-' ||
		    (*s->ptr >= '0' && *s->ptr <= '9'))
			return decode_number(s);
		return -1;
	}
}

/// json.decode(str) — upvalue 1 is json.null
static int ldecode(lua_State *L)
{
	size_t len;
	struct decode_state s;
	const char *str = luaL_checklstring(L, 1, &len);
	s.L = L;
	s.ptr = str;
	s.end = str + len;
	s.null_idx = NULL_UPVALUE;
	skip_space(&s);
	if (s.ptr >= s.end) {
		lua_pushnil(L);
		lua_pushliteral(L, "empty input");
		return 2;
	}
	if (decode_value(&s) < 0) {
		lua_pushnil(L);
		lua_pushliteral(L, "invalid json");
		return 2;
	}
	return 1;
}

/* json.null metatable */

static int lnull_tostring(lua_State *L)
{
	(void)L;
	lua_pushliteral(L, "null");
	return 1;
}

static int lnull_newindex(lua_State *L)
{
	return luaL_error(L, "attempt to modify json.null");
}

/* create json.null table with protected metatable, push onto stack */
static void create_json_null(lua_State *L)
{
	lua_newtable(L);
	lua_newtable(L); /* metatable */
	lua_pushcfunction(L, lnull_tostring);
	lua_setfield(L, -2, "__tostring");
	lua_pushcfunction(L, lnull_newindex);
	lua_setfield(L, -2, "__newindex");
	lua_pushboolean(L, 0);
	lua_setfield(L, -2, "__metatable");
	lua_setmetatable(L, -2);
}

SILLY_MOD_API int luaopen_silly_encoding_json(lua_State *L)
{
	luaL_Reg tbl[] = {
		{ "encode", lencode },
		{ "decode", ldecode },
		{ NULL,     NULL    },
	};
	luaL_checkversion(L);
	luaL_newlibtable(L, tbl);
	/* stack: lib */
	create_json_null(L);
	/* stack: lib, null */
	lua_pushvalue(L, -1);
	/* stack: lib, null, null_dup */
	lua_insert(L, -3);
	/* stack: null_dup, lib, null — lib at -(nup+1) for setfuncs */
	luaL_setfuncs(L, tbl, 1);
	/* stack: null_dup, lib */
	lua_insert(L, -2);
	/* stack: lib, null_dup */
	lua_setfield(L, -2, "null");
	/* stack: lib */
	return 1;
}
