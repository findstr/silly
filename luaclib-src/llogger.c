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
#include "luafmt.h"

#define LOG_TRUE_STR "true"
#define LOG_FALSE_STR "false"
#define LOG_NIL_STR "nil"
#define LOG_LF_STR "\n"

#define LOG_ESC '%'

#define LOG_TABLE_DEEP (5)

#define BUF_UPVALUE lua_upvalueindex(1)

/* Use cbuf as the log buffer (lazy allocation, 1024 initial capacity) */
#define CBUF_INIT_SIZE 1024
#include "cbuf.h"

static int lbuf_gc(lua_State *L)
{
	struct cbuf *b = (struct cbuf *)lua_touserdata(L, 1);
	cbuf_free(b);
	return 0;
}

/* ---- formatting helpers ---- */

static inline void lbuf_addbool(struct cbuf *b, lua_State *L, int arg)
{
	if (lua_toboolean(L, arg)) {
		cbuf_addlstr(b, LOG_TRUE_STR, sizeof(LOG_TRUE_STR) - 1);
	} else {
		cbuf_addlstr(b, LOG_FALSE_STR, sizeof(LOG_FALSE_STR) - 1);
	}
}

static inline void lbuf_addnil(struct cbuf *b)
{
	cbuf_addlstr(b, LOG_NIL_STR, sizeof(LOG_NIL_STR) - 1);
}

static inline void lbuf_addvalue(struct cbuf *b, lua_State *L, int arg)
{
	size_t len;
	int top = lua_gettop(L);
	const char *s = luaL_tolstring(L, arg, &len);
	cbuf_addchar(b, '"');
	cbuf_addlstr(b, s, len);
	cbuf_addchar(b, '"');
	if (top != lua_gettop(L)) {
		lua_settop(L, top);
	}
}

static inline void log_field(lua_State *L, struct cbuf *b, int stk,
			     int type, int deep)
{
	size_t sz;
	int first;
	const char *str;
	if (unlikely(deep > LOG_TABLE_DEEP)) {
		return;
	}
	luaL_checkstack(L, deep + LUA_MINSTACK, "too many nested tables");
	switch (type) {
	case LUA_TSTRING:
		str = lua_tolstring(L, stk, &sz);
		cbuf_addlstr(b, str, sz);
		break;
	case LUA_TNUMBER:
		if (lua_isinteger(L, stk)) {
			char buf[32];
			lua_Integer n = lua_tointeger(L, stk);
			int len = luafmt_int64(buf, (int64_t)n);
			cbuf_addlstr(b, buf, len);
		} else {
			int len;
			char buf[32];
			lua_Number n = lua_tonumber(L, stk);
			len = snprintf(buf, sizeof(buf), LUA_NUMBER_FMT, n);
			if (len > 0 && len < (int)sizeof(buf)) {
				cbuf_addlstr(b, buf, len);
			} else {
				lbuf_addvalue(b, L, stk);
			}
		}
		break;
	case LUA_TBOOLEAN:
		lbuf_addbool(b, L, stk);
		break;
	case LUA_TTABLE:
		first = 1;
		cbuf_addchar(b, '{');
		if (deep == LOG_TABLE_DEEP) {
			cbuf_addlstr(b, "...", 3);
			cbuf_addchar(b, '}');
			break;
		}
		lua_pushnil(L);
		while (lua_next(L, stk) != 0) {
			if (first) {
				first = 0;
			} else {
				cbuf_addchar(b, ',');
			}
			int key_stk = lua_absindex(L, -2);
			int key_type = lua_type(L, key_stk);
			int val_stk = lua_absindex(L, -1);
			int val_type = lua_type(L, val_stk);
			if (key_type == LUA_TSTRING) {
				log_field(L, b, key_stk, key_type, deep + 1);
			} else {
				cbuf_addchar(b, '[');
				log_field(L, b, key_stk, key_type, deep + 1);
				cbuf_addchar(b, ']');
			}
			cbuf_addchar(b, '=');
			if (val_type == LUA_TSTRING) {
				cbuf_addchar(b, '"');
				log_field(L, b, val_stk, val_type, deep + 1);
				cbuf_addchar(b, '"');
			} else {
				log_field(L, b, val_stk, val_type, deep + 1);
			}
			lua_pop(L, 1);
		}
		cbuf_addchar(b, '}');
		break;
	case LUA_TNIL:
		lbuf_addnil(b);
		break;
	default:
		lbuf_addvalue(b, L, stk);
		break;
	}
}

static inline void log_file_line(lua_State *L, struct cbuf *b)
{
	lua_Debug ar;
	if (lua_getstack(L, 1, &ar)) {     /* check function at level */
		lua_getinfo(L, "Sl", &ar); /* get info about it */
		if (ar.currentline > 0) {  /* is there info? */
			size_t maxsize = PATH_MAX + 32;
			char *ptr = cbuf_prepbuffsize(b, maxsize);
			int n = snprintf(ptr, maxsize, "%s:%d ",
					 ar.short_src, ar.currentline);
			if (n > 0 && (size_t)n < maxsize)
				cbuf_addsize(b, n);
		}
	}
}

/* ---- log entry formatting ---- */

/// log(...)
static int llog(lua_State *L, enum silly_log_level log_level)
{
	int stk, top;
	struct cbuf *b = (struct cbuf *)lua_touserdata(L, BUF_UPVALUE);
	if (!silly_log_visible(log_level)) {
		return 0;
	}
	top = lua_gettop(L);
	cbuf_reset(b);
#ifdef LOG_ENABLE_FILE_LINE
	log_file_line(L, b);
#endif
	for (stk = 1; stk <= top; stk++) {
		int type = lua_type(L, stk);
		log_field(L, b, stk, type, 0);
		cbuf_addchar(b, ' ');
	}
	cbuf_addchar(b, '\n');
	silly_log_write(log_level, b->data, b->len);
	return 0;
}

/// logf(fmt, ...)
static int llogf(lua_State *L, enum silly_log_level log_level)
{
	int top;
	int arg = 1;
	struct luastr fmt;
	struct cbuf *b = (struct cbuf *)lua_touserdata(L, BUF_UPVALUE);
	const char *strfmt, *strfmt_end;
	if (!silly_log_visible(log_level)) {
		return 0;
	}
	top = lua_gettop(L);
	cbuf_reset(b);
#ifdef LOG_ENABLE_FILE_LINE
	log_file_line(L, b);
#endif
	luastr_check(L, 1, &fmt);
	strfmt = (const char *)fmt.str;
	strfmt_end = strfmt + fmt.len;
	while (strfmt < strfmt_end) {
		if (*strfmt != LOG_ESC) {
			cbuf_addchar(b, *strfmt++);
		} else if (*++strfmt == LOG_ESC) {
			cbuf_addchar(b, *strfmt++); /* %% */
		} else { /* format item */
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
			log_field(L, b, arg, lua_type(L, arg), 0);
			cbuf_addchar(b, ' ');
		}
	}
	cbuf_addchar(b, '\n');
	silly_log_write(log_level, b->data, b->len);
	return 0;
}

/* ---- Lua exports ---- */

static int lopenfile(lua_State *L)
{
	const char *path = luaL_checkstring(L, 1);
	silly_log_open_file(path);
	return 0;
}

static int lgetlevel(lua_State *L)
{
	enum silly_log_level level = silly_log_get_level();
	lua_pushinteger(L, level);
	return 1;
}

static int lsetlevel(lua_State *L)
{
	int level = luaL_optinteger(L, 1, (lua_Integer)SILLY_LOG_INFO);
	silly_log_set_level(level);
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

SILLY_MOD_API int luaopen_silly_logger_c(lua_State *L)
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
	struct cbuf *b;
	luaL_checkversion(L);
	luaL_newlibtable(L, tbl);
	/* create logger_buf userdata as shared upvalue */
	b = (struct cbuf *)lua_newuserdatauv(L, sizeof(struct cbuf), 0);
	cbuf_init(b);
	/* set __gc metamethod */
	lua_newtable(L);
	lua_pushcfunction(L, lbuf_gc);
	lua_setfield(L, -2, "__gc");
	lua_setmetatable(L, -2);
	/* stack: lib, udata */
	luaL_setfuncs(L, tbl, 1);
	/* stack: lib */
	return 1;
}
