#include <assert.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>
#include <string.h>
#include "silly.h"
#include "silly_trace.h"
#include "silly_log.h"
#include "silly_env.h"
#include "silly_timer.h"
#include "silly_run.h"

#define ARRAY_SIZE(a)	(sizeof(a) / sizeof(a[0]))

static inline int
optint(const char *key, int v)
{
	int n;
	int len;
	char *end;
	const char *val;
	val = silly_env_get(key);
	if (val == NULL)
		return v;
	len = strlen(val);
	errno = 0;
	n = strtol(val, &end, 0);
	if (errno != 0 || end != (val + len)) {
		const char *fmt = "[config] incorrect value of '%s' %s\n";
		silly_log_error(fmt, key);
		exit(-1);
	}
	return n;
}

static inline const char *
optstr(const char *key, size_t *sz, const char *v)
{
	const char *str;
	str = silly_env_get(key);
	if (str == NULL)
		str = v;
	*sz = strlen(str);
	return str;
}

static void
enveach(lua_State *L, char *first, char *curr, char *end)
{
	lua_pushnil(L);
	while (lua_next(L, -2) != 0) {
		size_t sz;
		const char *k;
		int type = lua_type(L, -2);
		if (type != LUA_TSTRING && type != LUA_TNUMBER) {
			silly_log_error("[checktype] key expecte string/number"
				" but got %s\n", lua_typename(L, type));
			exit(-1);
		}
		lua_pushvalue(L, -2);
		k = lua_tolstring(L, -1, &sz);
		assert(curr <= end);
		if (sz >= (size_t)(end - curr)) {
			silly_log_error("[enveach] buff is too short\n");
			exit(-1);
		}
		lua_pop(L, 1);
		memcpy(curr, k, sz);
		if (lua_type(L, -1) == LUA_TTABLE) {
			curr[sz] = '.';
			enveach(L, first, &curr[sz + 1], end);
		} else {
			int type = lua_type(L, -1);
			if (type != LUA_TSTRING && type != LUA_TNUMBER) {
				const char *fmt = "[enveach]"
					"%s expect string/number bug got:%s\n";
				silly_log_error(fmt, lua_typename(L, type));
			}
			const char *value = lua_tostring(L, -1);
			curr[sz] = '\0';
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
initenv(const char *self, const char *file)
{
	int err;
	char name[256] = {0};
	lua_State *L = luaL_newstate();
	luaL_openlibs(L);
	err = luaL_loadstring(L, load_config);
	lua_pushstring(L, file);
	assert(err == LUA_OK);
	err = lua_pcall(L, 1, 1, 0);
	if (err != LUA_OK) {
		const char *err = lua_tostring(L, -1);
		err = skipcode(err);
		silly_log_error("%s parse config file:%s fail,%s\n",
			self, file, err);
		lua_close(L);
		exit(-1);
	}
	enveach(L, name, name, &name[256]);
	lua_close(L);
	return ;
}

static void
applyconfig(struct silly_config *config)
{
	int slash;
	char *p;
	size_t i, sz, n;
	const char *str;
	config->daemon = optint("daemon", 0);
	//bootstrap
	str = optstr("bootstrap", &sz, "");
	if (sz >= ARRAY_SIZE(config->bootstrap)) {
		silly_log_error("[config] bootstrap is too long\n");
		exit(-1);
	}
	if (sz == 0) {
		silly_log_error("[config] bootstrap can't be empty\n");
		exit(-1);
	}
	memcpy(config->bootstrap, str, sz + 1);
	//lualib_path
	str = optstr("lualib_path", &sz, "");
	if (sz >= ARRAY_SIZE(config->lualib_path)) {
		silly_log_error("[config] lualib_path is too long\n");
		exit(-1);
	}
	memcpy(config->lualib_path, str, sz + 1);
	//lualib_cpath
	str = optstr("lualib_cpath", &sz, "");
	if (sz >= ARRAY_SIZE(config->lualib_cpath)) {
		silly_log_error("[config] lualib_cpath is too long\n");
		exit(-1);
	}
	memcpy(config->lualib_cpath, str, sz + 1);
	//logpath
	str = optstr("logpath", &sz, "");
	slash = sz > 0 ? str[sz - 1] : '/';
	p = config->logpath;
	n = ARRAY_SIZE(config->logpath);
	if (slash == '/')
		sz = snprintf(p, n, "%s%s.log", str, config->selfname);
	else
		sz = snprintf(p, n, "%s", str);
	if (sz >= n) {
		silly_log_error("[config] logpath is too long\n");
		exit(-1);
	}
	//log level
	struct {
		const char *name;
		enum silly_log_level level;
	} loglevels[] = {
		{"debug",	SILLY_LOG_DEBUG},
		{"info",	SILLY_LOG_INFO},
		{"warn",	SILLY_LOG_WARN},
		{"error",	SILLY_LOG_ERROR},
	};
	str = optstr("loglevel", &sz, "");
	for (i = 0; i < ARRAY_SIZE(loglevels); i++) {
		if (strcmp(loglevels[i].name, str) == 0) {
			silly_log_setlevel(loglevels[i].level);
			break;
		}
	}
	//pidfile
	str = optstr("pidfile", &sz, "");
	if ((sz + 1) >= ARRAY_SIZE(config->pidfile)) {
		silly_log_error("[config] pidfile is too long\n");
		exit(-1);
	}
	memcpy(config->pidfile, str, sz + 1);
	//cpu affinity
	config->socketaffinity= optint("socket_cpu_affinity", -1);
	config->workeraffinity = optint("worker_cpu_affinity", -1);
	config->timeraffinity = optint("timer_cpu_affinity", -1);
	return;
}

static const char *
selfname(const char *path)
{
	size_t len = strlen(path);
	const char *end = &path[len];
	while (end-- > path) {
		if (*end == '/' || *end == '\\')
			break;
	}
	return (end + 1);
}

int main(int argc, char *argv[])
{
	int i, status;
	struct silly_config config;
	if (argc < 2) {
		printf("USAGE:%s <config file> --parameters\n", argv[0]);
		return -1;
	}
	silly_trace_init();
	silly_env_init();
	silly_log_init();
	silly_timer_init();
	config.selfname = selfname(argv[0]);
	i = 1;
	//first argument is t he config file name?
	if (argv[i][0] != '-' || argv[i][1] != '-')
		initenv(config.selfname, argv[i++]);
	while (i < argc) {
		if (argv[i][0] != '-' || argv[i][1] != '-') {
			silly_log_error("[config] skip argument '%s'\n", argv[i]);
		} else {
			const char *k, *v;
			char *str = argv[i];
			k = strtok(&str[2], "=");
			v = strtok(NULL, "=");
			if (k == NULL || v == NULL)
				silly_log_error("[config] skip argument '%s'\n", str);
			else
				silly_env_set(k, v);
		}
		++i;
	}
	applyconfig(&config);
	status = silly_run(&config);
	silly_env_exit();
	silly_log_info("%s exit, leak memory size:%zu\n",
		argv[0], silly_memused());
	silly_log_flush();
	return status;
}

