#include <assert.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <stddef.h>
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>

#include "silly.h"
#include "compiler.h"
#include "silly_log.h"

#define LOG_TRUE_STR "true"
#define LOG_FALSE_STR "false"
#define LOG_NIL_STR "nil"
#define LOG_LF_STR "\n"

#define LOG_TABLE_DEEP (5)

struct log_buffer {
	char buf[LOG_BUF_SIZE];
	char *ptr;
};

static inline void
log_buffer_init(struct log_buffer *b)
{
	b->ptr = b->buf;
}

static inline size_t
log_buffer_space(struct log_buffer *b)
{
	return (size_t)(&b->buf[LOG_BUF_SIZE] - b->ptr);
}

static void
log_buffer_append(struct log_buffer *b, const char *str, size_t len)
{
	if (log_buffer_space(b) < len)
		return;
	memcpy(b->ptr, str, len);
	b->ptr += len;
	return;
}

static void
log_buffer_addchar(struct log_buffer *b, char c)
{
	if (log_buffer_space(b) < 1)
		return;
	*b->ptr++ = c;
}

static char *
inttostr(lua_Integer n, char *begin, char *end)
{
	int neg = 0;
	if (n < 0) {
		neg = 1;
		n = -n;
	}
	do {
		int m = n % 10;
		n /= 10;
		*(--end) = m + '0';
	} while (begin < end && n > 0);
	if (neg && begin < end)
		*(--end) = '-';
	return end;
}

static inline void
log_field(lua_State *L, struct log_buffer *b, int stk, int type, int deep)
{
	size_t sz;
	const char *str;
	if (unlikely(deep > LOG_TABLE_DEEP)) {
		return;
	}
	switch (type) {
	case LUA_TSTRING:
		str = lua_tolstring(L, stk, &sz);
		log_buffer_append(b, str, sz);
		break;
	case LUA_TNUMBER:
		if (lua_isinteger(L, stk)) {
			char buf[32];
			lua_Integer n = lua_tointeger(L, stk);
			char *end = &buf[sizeof(buf)/sizeof(buf[0])];
			char *start = inttostr(n, buf, end);
			log_buffer_append(b, start, end - start);
		} else {
			int len;
			char buf[32];
			lua_Number n = lua_tonumber(L, stk);
			len = snprintf(buf, sizeof(buf), LUA_NUMBER_FMT, n);
			log_buffer_append(b, buf, len);
		}
		break;
	case LUA_TBOOLEAN:
		if (lua_toboolean(L, stk))
			log_buffer_append(b, LOG_TRUE_STR, sizeof(LOG_TRUE_STR) - 1);
		else
			log_buffer_append(b, LOG_FALSE_STR, sizeof(LOG_FALSE_STR) - 1);
		break;
	case LUA_TTABLE:
		log_buffer_addchar(b, '{');
		lua_pushnil(L);
		while (lua_next(L, stk) != 0) {
			int key_stk = lua_absindex(L, -2);
			int key_type = lua_type(L, key_stk);
			int val_stk = lua_absindex(L, -1);
			int val_type = lua_type(L, val_stk);
			if (key_type == LUA_TSTRING) {
				log_field(L, b, key_stk, key_type, deep + 1);
			} else {
				log_buffer_addchar(b, '[');
				log_field(L, b, key_stk, key_type, deep + 1);
				log_buffer_addchar(b, ']');
			}
			log_buffer_addchar(b, '=');
			if (val_type == LUA_TSTRING) {
				log_buffer_addchar(b, '"');
				log_field(L, b, val_stk, val_type, deep + 1);
				log_buffer_addchar(b, '"');
			} else {
				log_field(L, b, val_stk, val_type, deep + 1);
			}
			log_buffer_addchar(b, ',');
			lua_pop(L, 1);
		}
		log_buffer_addchar(b, '}');
		break;
	case LUA_TNIL:
		log_buffer_append(b, LOG_NIL_STR, sizeof(LOG_NIL_STR) - 1);
		break;
	default:
		luaL_error(L, "log unspport param#%d type:%s",
			stk, lua_typename(L, type));
		break;
	}
}

static int
llog(lua_State *L, enum silly_log_level log_level)
{
	int stk, top;
	struct log_buffer buffer;
	if (!silly_log_visible(log_level)) {
		return 0;
	}
	top = lua_gettop(L);
	silly_log_head(log_level);
	log_buffer_init(&buffer);
	for (stk = 1; stk <= top; stk++) {
		int type = lua_type(L, stk);
		log_field(L, &buffer, stk, type, 0);
		log_buffer_addchar(&buffer, ' ');
	}
	log_buffer_addchar(&buffer, '\n');
	silly_log_append(buffer.buf, buffer.ptr - buffer.buf);
	return 0;
}

static int
lgetlevel(lua_State *L)
{
	enum silly_log_level level = silly_log_getlevel();
	lua_pushinteger(L, level);
	return 1;
}

static int
lsetlevel(lua_State *L)
{
	int level = luaL_optinteger(L, 1, (lua_Integer)SILLY_LOG_INFO);
	silly_log_setlevel(level);
	return 0;
}

static int
ldebug(lua_State *L)
{
	return llog(L, SILLY_LOG_DEBUG);
}

static int
linfo(lua_State *L)
{
	return llog(L, SILLY_LOG_INFO);
}

static int
lwarn(lua_State *L)
{
	return llog(L, SILLY_LOG_WARN);
}

static int
lerror(lua_State *L)
{
	return llog(L, SILLY_LOG_ERROR);
}

int
luaopen_sys_logger_c(lua_State *L)
{
	luaL_Reg tbl[] = {
		{"getlevel", lgetlevel},
		{"setlevel", lsetlevel},
		{"debug", ldebug},
		{"info", linfo},
		{"warn", lwarn},
		{"error", lerror},
		//end
		{NULL, NULL},
	};

	luaL_checkversion(L);
	luaL_newlib(L, tbl);
	return 1;
}

