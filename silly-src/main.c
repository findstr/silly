#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>
#include <string.h>
#include "silly.h"
#include "silly_log.h"
#include "silly_env.h"
#include "silly_run.h"

#define ARRAY_SIZE(a)	(sizeof(a) / sizeof(a[0]))

static int
checktype(lua_State *L, const char *key, int skt, int type)
{
	int t = lua_type(L, skt);
	if (t == LUA_TNIL)
		return -1;
	if (t != type && t != LUA_TNIL) {
		const char *expect = lua_typename(L, type);
		const char *got = lua_typename(L, lua_type(L, skt));
		const char *fmt = "[checktype] %s expecte %s but got %s\n";
		silly_log(fmt, key, expect, got);
		exit(-1);
	}
	return 0;
}

static int
optint(lua_State *L, const char *key, int v)
{
	int n;
	int nil;
	lua_getfield(L, -1, key);
	nil = checktype(L, key, -1, LUA_TNUMBER);
	if (nil < 0)
		n = v;
	else
		n = lua_tonumber(L, -1);
	lua_pop(L, 1);
	return n;
}

static const char *
optstr(lua_State *L, const char *key, size_t *sz, const char *v)
{
	int nil;
	const char *str;
	lua_getfield(L, -1, key);
	nil = checktype(L, key, -1, LUA_TSTRING);
	if (nil < 0) {
		str = v;
		*sz = strlen(str);
	} else {
		str = lua_tolstring(L, -1, sz);
	}
	lua_pop(L, 1);
	return str;
}



static void
enveach(lua_State *L, char *first, char *curr, char *end)
{
	lua_pushnil(L);
	while (lua_next(L, -2) != 0) {
		size_t sz;
		const char *k;
		checktype(L, "[enveach] key", -2, LUA_TSTRING);
		k = lua_tolstring(L, -2, &sz);
		assert(curr <= end);
		if (sz >= (size_t)(end - curr)) {
			silly_log("[enveach] buff is too short\n");
			exit(-1);
		}
		memcpy(curr, k, sz);
		if (lua_type(L, -1) == LUA_TTABLE) {
			curr[sz] = '.';
			enveach(L, first, &curr[sz + 1], end);
		} else {
			int type = lua_type(L, -1);
			if (type != LUA_TSTRING && type != LUA_TNUMBER) {
				const char *fmt = "[enveach]"
					"%s expect string/number bug got:%s\n";
				silly_log(fmt, lua_typename(L, type));
			}
			const char *value = lua_tostring(L, -1);
			curr[sz] = '\0';
			char *eval = getenv(first);
			if (eval)
				value = eval;
			silly_env_set(first, value);
		}
		lua_pop(L, 1);
	}
	return ;
}

static const char *load_config = "\
	local config = {}\
	local function include(name)\
		local f = io.open(name, 'r')\
		if not f then\
			error('open config error of file:' .. name)\
		end\
		local code = f:read('a')\
		if not code then\
			error('read config error of file:' .. name)\
		end\
		f:close()\
		assert(load(code, name, 't', config))()\
		return \
	end\
	config.include = include\
	include(...)\
	config.include = nil\
	return config\
	";

static const char *
skipcode(const char *str)
{
	while (*str && *str++ != ']')
		;
	if (*str)
		str += 3;
	return str;
}

static void
initenv(lua_State *L, const char *self, const char *file)
{
	int err;
	char name[256] = {0};
	luaL_openlibs(L);
	err = luaL_loadstring(L, load_config);
	lua_pushstring(L, file);
	assert(err == LUA_OK);
	err = lua_pcall(L, 1, 1, 0);
	if (err != LUA_OK) {
		const char *err = lua_tostring(L, -1);
		err = skipcode(err);
		silly_log("%s parse config file:%s fail,%s\n",
			self, file, err);
		lua_close(L);
		exit(-1);
	}
	return enveach(L, name, name, &name[256]);
}

static void
parseconfig(lua_State *L, struct silly_config *config)
{
	size_t sz;
	int slash;
	const char *str;
	config->daemon = optint(L, "daemon", 0);
	//bootstrap
	str = optstr(L, "bootstrap", &sz, "");
	if (sz >= ARRAY_SIZE(config->bootstrap)) {
		silly_log("[config] bootstrap is too long\n");
		exit(-1);
	}
	if (sz == 0) {
		silly_log("[config] bootstrap can't be empty\n");
		exit(-1);
	}
	memcpy(config->bootstrap, str, sz + 1);
	//lualib_path
	str = optstr(L, "lualib_path", &sz, "");
	if (sz >= ARRAY_SIZE(config->lualib_path)) {
		silly_log("[config] lualib_path is too long\n");
		exit(-1);
	}
	memcpy(config->lualib_path, str, sz + 1);
	//lualib_cpath
	str = optstr(L, "lualib_cpath", &sz, "");
	if (sz >= ARRAY_SIZE(config->lualib_cpath)) {
		silly_log("[config] lualib_cpath is too long\n");
		exit(-1);
	}
	memcpy(config->lualib_cpath, str, sz + 1);
	//logpath
	str = optstr(L, "logpath", &sz, "");
	if ((sz + 1) >= ARRAY_SIZE(config->logpath)) { //reserve one byte for /
		silly_log("[config] logpath is too long\n");
		exit(-1);
	}
	memcpy(config->logpath, str, sz + 1);
	slash = '/';
	if (sz > 0)
		slash = config->logpath[sz - 1];
	if (slash != '/') {
		config->logpath[sz] = '/';
		config->logpath[sz + 1] = 0;
	}
	//pidfile
	str = optstr(L, "pidfile", &sz, "");
	if ((sz + 1) >= ARRAY_SIZE(config->pidfile)) {
		silly_log("[config] pidfile is too long\n");
		exit(-1);
	}
	memcpy(config->pidfile, str, sz + 1);
	return;
}

int main(int argc, char *argv[])
{
	lua_State *L;
	struct silly_config config;
	if (argc != 2) {
		printf("USAGE:%s <config file>\n", argv[0]);
		return -1;
	}
	silly_env_init();
	L = luaL_newstate();
	initenv(L, argv[0], argv[1]);
	config.selfname = argv[0];
	parseconfig(L, &config);
	lua_close(L);
	silly_run(&config);
	silly_env_exit();
	silly_log("%s exit, leak memory size:%zu\n",
		argv[0], silly_memused());
	return 0;
}
