#include <assert.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <stddef.h>
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>

#include "silly.h"
#include "luastr.h"

#define LOG_TRUE_STR "true"
#define LOG_FALSE_STR "false"
#define LOG_NIL_STR "nil"
#define LOG_LF_STR "\n"

#define LOG_ESC '%'

#define LOG_TABLE_DEEP (5)

struct log_buffer {
	char buf[LOG_BUF_SIZE];
	char *b;
	size_t n;
	size_t size;
};

static inline void log_buffer_init(struct log_buffer *b)
{
	b->b = b->buf;
	b->n = 0;
	b->size = LOG_BUF_SIZE;
}

static inline void log_buffer_free(struct log_buffer *b)
{
	if (b->b != b->buf) {
		silly_free(b->b);
		log_buffer_init(b);
	}
}

static inline void *log_buffer_prepbuffsize(struct log_buffer *b, size_t len)
{
	size_t need = b->n + len;
	if (need > b->size) {
		if (b->b == b->buf) {
			b->b = silly_malloc(need);
			memcpy(b->b, b->buf, b->n);
		} else {
			b->b = silly_realloc(b->b, need);
		}
		b->size = need;
	}
	return b->b + b->n;
}

static inline void log_buffer_addsize(struct log_buffer *b, size_t len)
{
	b->n += len;
	assert(b->n <= b->size);
}

static inline void log_buffer_append(struct log_buffer *b, const char *str,
				     size_t len)
{
	char *ptr = log_buffer_prepbuffsize(b, len);
	memcpy(ptr, str, len);
	b->n += len;
	return;
}

static void log_buffer_addchar(struct log_buffer *b, char c)
{
	log_buffer_prepbuffsize(b, 1);
	b->b[b->n++] = c;
}

static void log_buffer_addvalue(struct log_buffer *b, lua_State *L, int arg)
{
	size_t len;
	int top = lua_gettop(L);
	const char *s = lua_tolstring(L, arg, &len);
	char *ptr = log_buffer_prepbuffsize(b, len);
	memcpy(ptr, s, len);
	log_buffer_addsize(b, len);
	if (top != lua_gettop(L)) {
		lua_settop(L, top);
	}
}

static void log_buffer_addbool(struct log_buffer *b, lua_State *L, int arg)
{
	if (lua_toboolean(L, arg)) {
		log_buffer_append(b, LOG_TRUE_STR, sizeof(LOG_TRUE_STR) - 1);
	} else {
		log_buffer_append(b, LOG_FALSE_STR, sizeof(LOG_FALSE_STR) - 1);
	}
}

static void log_buffer_addnil(struct log_buffer *b)
{
	log_buffer_append(b, LOG_NIL_STR, sizeof(LOG_NIL_STR) - 1);
}

static char *inttostr(lua_Integer n, char *begin, char *end)
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

static inline void log_field(lua_State *L, struct log_buffer *b, int stk,
			     int type, int deep)
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
			char *end = &buf[sizeof(buf) / sizeof(buf[0])];
			char *start = inttostr(n, buf, end);
			log_buffer_append(b, start, end - start);
		} else {
			int len;
			char buf[32];
			lua_Number n = lua_tonumber(L, stk);
			len = snprintf(buf, sizeof(buf), LUA_NUMBER_FMT, n);
			if (len > 0 && len < (int)sizeof(buf)) {
				log_buffer_append(b, buf, len);
			} else {
				log_buffer_addvalue(b, L, stk);
			}
		}
		break;
	case LUA_TBOOLEAN:
		log_buffer_addbool(b, L, stk);
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
		log_buffer_addnil(b);
		break;
	default:
		log_buffer_addvalue(b, L, stk);
		break;
	}
}

static inline void log_file_line(lua_State *L, struct log_buffer *buffer)
{
	lua_Debug ar;
	if (lua_getstack(L, 1, &ar)) {     /* check function at level */
		lua_getinfo(L, "Sl", &ar); /* get info about it */
		if (ar.currentline > 0) {  /* is there info? */
			size_t maxsize = PATH_MAX + 32;
			char *buf = log_buffer_prepbuffsize(buffer, maxsize);
			int n = snprintf(buf, maxsize, "%s:%d ", ar.short_src,
					 ar.currentline);
			if (n >= 0 && n < (int)maxsize) {
				log_buffer_addsize(buffer, n);
			}
		}
	}
}

static int llog(lua_State *L, enum silly_log_level log_level)
{
	int stk, top;
	struct log_buffer buffer;
	if (!silly_log_visible(log_level)) {
		return 0;
	}
	top = lua_gettop(L);
	log_buffer_init(&buffer);
#ifdef LOG_ENABLE_FILE_LINE
	log_file_line(L, &buffer);
#endif
	for (stk = 1; stk <= top; stk++) {
		int type = lua_type(L, stk);
		log_field(L, &buffer, stk, type, 0);
		log_buffer_addchar(&buffer, ' ');
	}
	log_buffer_addchar(&buffer, '\n');
	silly_log_head(log_level);
	silly_log_append(buffer.b, buffer.n);
	log_buffer_free(&buffer);
	return 0;
}

/// logf(fmt, ...)
static int llogf(lua_State *L, enum silly_log_level log_level)
{
	int top;
	int arg = 1;
	struct luastr fmt;
	struct log_buffer buffer;
	const char *strfmt, *strfmt_end;
	if (!silly_log_visible(log_level)) {
		return 0;
	}
	top = lua_gettop(L);
	luastr_check(L, arg, &fmt);
	log_buffer_init(&buffer);
#ifdef LOG_ENABLE_FILE_LINE
	log_file_line(L, &buffer);
#endif
	strfmt = (const char *)fmt.str;
	strfmt_end = strfmt + fmt.len;
	while (strfmt < strfmt_end) {
		if (*strfmt != LOG_ESC)
			log_buffer_addchar(&buffer, *strfmt++);
		else if (*++strfmt == LOG_ESC)
			log_buffer_addchar(&buffer, *strfmt++); /* %% */
		else { /* format item */
			if (*strfmt != 's') {
				const char *err = "invalid option "
						  "'%%%c' to 'format',"
						  " only support '%%s'";
				luaL_error(L, err, *strfmt);
			}
			++strfmt;
			if (++arg > top) {
				luaL_error(L, "no value");
			}
			log_field(L, &buffer, arg, lua_type(L, arg), 0);
			log_buffer_addchar(&buffer, ' ');
		}
	}
	log_buffer_addchar(&buffer, '\n');
	silly_log_head(log_level);
	silly_log_append(buffer.b, buffer.n);
	log_buffer_free(&buffer);
	return 0;
}

static int lopenfile(lua_State *L)
{
	const char *path = luaL_checkstring(L, 1);
	silly_log_openfile(path);
	return 0;
}

static int lgetlevel(lua_State *L)
{
	enum silly_log_level level = silly_log_getlevel();
	lua_pushinteger(L, level);
	return 1;
}

static int lsetlevel(lua_State *L)
{
	int level = luaL_optinteger(L, 1, (lua_Integer)SILLY_LOG_INFO);
	silly_log_setlevel(level);
	return 0;
}

static int ldebug(lua_State *L)
{
	return llog(L, SILLY_LOG_DEBUG);
}

static int linfo(lua_State *L)
{
	return llog(L, SILLY_LOG_INFO);
}

static int lwarn(lua_State *L)
{
	return llog(L, SILLY_LOG_WARN);
}

static int lerror(lua_State *L)
{
	return llog(L, SILLY_LOG_ERROR);
}

static int ldebugf(lua_State *L)
{
	return llogf(L, SILLY_LOG_DEBUG);
}

static int linfof(lua_State *L)
{
	return llogf(L, SILLY_LOG_INFO);
}

static int lwarnf(lua_State *L)
{
	return llogf(L, SILLY_LOG_WARN);
}

static int lerrorf(lua_State *L)
{
	return llogf(L, SILLY_LOG_ERROR);
}

SILLY_MOD_API int luaopen_core_logger_c(lua_State *L)
{
	luaL_Reg tbl[] = {
		{ "openfile", lopenfile },
		{ "getlevel", lgetlevel },
		{ "setlevel", lsetlevel },
		// log print
		{ "debug",    ldebug    },
		{ "info",     linfo     },
		{ "warn",     lwarn     },
		{ "error",    lerror    },
		// log printf
		{ "debugf",   ldebugf   },
		{ "infof",    linfof    },
		{ "warnf",    lwarnf    },
		{ "errorf",   lerrorf   },
		//end
		{ NULL,       NULL      },
	};

	luaL_checkversion(L);
	luaL_newlib(L, tbl);
	return 1;
}