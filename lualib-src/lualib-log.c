#include <assert.h>
#include <unistd.h>
#include <time.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <arpa/inet.h>
#include <lua.h>
#include <lauxlib.h>

#include "silly_timer.h"
#include "silly_env.h"

static int today = -1;
static pid_t pid = 0;
static FILE *fp = NULL;
static char path[PATH_MAX];

static int
lfile(lua_State *L)
{
	size_t sz;
	const char *str = luaL_checklstring(L, 1, &sz);
	if (sz > PATH_MAX - 30) {
		lua_pushboolean(L, 0);
		return 1;
	}
	strncpy(path, str, PATH_MAX);
	lua_pushboolean(L, 1);
	return 1;
}

static int
lprint(lua_State *L)
{
	struct tm fmt;
	time_t now = time(NULL);
	char indent[128];
	int i;
	int paramn = lua_gettop(L);
	localtime_r(&now, &fmt);
	if (today != fmt.tm_mday) { //do split
		today = fmt.tm_mday;
		if (fp)
			fclose(fp);
		pid = getpid();
		char newpath[PATH_MAX];
		snprintf(newpath, PATH_MAX, "%s.%d-%02d-%02d",
				path,
				fmt.tm_year + 1900,
				fmt.tm_mon + 1,
				fmt.tm_mday
				);
		fp = fopen(newpath, "ab+");
		if (fp == NULL) {
			fprintf(stderr, "[log] create log file:%s fail\n", newpath);
			return 0;
		}
	}
	snprintf(indent, sizeof(indent) / sizeof(indent[0]), "[%02d:%02d:%02d] [%d]",
		fmt.tm_hour,
		fmt.tm_min,
		fmt.tm_sec,
		pid
	);
	fprintf(fp, indent);
	for (i = 1; i <= paramn; i++) {
		int type = lua_type(L, i);
		switch (type) {
		case LUA_TSTRING:
			fprintf(fp, "%s ", lua_tostring(L, i));
			break;
		case LUA_TNUMBER:
			fprintf(fp, "%d ", (int)lua_tointeger(L, i));
			break;
		case LUA_TBOOLEAN:
			fprintf(fp, "%s ", lua_toboolean(L, i) ? "true" : "false");
			break;
		case LUA_TNIL:
			fprintf(fp, "#%d.null ", i);
			break;
		default:
			return luaL_error(L, "log unspport param#%d type:%s",
				i, lua_typename(L, type));
		}
	}
	fprintf(fp, "\n");
	fflush(fp);
	return 0;
}

int
luaopen_log(lua_State *L)
{
	luaL_Reg tbl[] = {
		{"file", lfile},
		{"print", lprint},
		{NULL, NULL},
	};

	luaL_checkversion(L);
	luaL_newlib(L, tbl);

	return 1;
}
