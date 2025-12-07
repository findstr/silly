#include <unistd.h>
#include <assert.h>
#include <errno.h>
#include <signal.h>
#include <stdlib.h>
#include <stdio.h>
#include <stddef.h>
#include <string.h>
#include <sys/time.h>
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>

#include "silly.h"

static int lexit(lua_State *L)
{
	int status;
	status = luaL_optinteger(L, 1, 0);
	silly_exit(status);
	return 0;
}

static int lgenid(lua_State *L)
{
	uint32_t id = silly_genid();
	lua_pushinteger(L, id);
	return 1;
}

static int ltostring(lua_State *L)
{
	char *buff;
	int size;
	buff = lua_touserdata(L, 1);
	size = luaL_checkinteger(L, 2);
	lua_pushlstring(L, buff, size);
	return 1;
}

static int lregister(lua_State *L)
{
	silly_callback_table(L);
	lua_pushvalue(L, 1);
	lua_pushvalue(L, 2);
	lua_settable(L, -3);
	return 0;
}

static int lsignalmap(lua_State *L)
{
#define SIG_NAME(name) { #name, name }
	size_t i;
	lua_newtable(L);
	struct signal {
		const char *name;
		int signum;
	} signals[] = {
		SIG_NAME(SIGINT),  SIG_NAME(SIGILL),  SIG_NAME(SIGABRT),
		SIG_NAME(SIGFPE),  SIG_NAME(SIGSEGV), SIG_NAME(SIGTERM),
#ifndef __WIN32
		SIG_NAME(SIGHUP),  SIG_NAME(SIGQUIT), SIG_NAME(SIGTRAP),
		SIG_NAME(SIGKILL), SIG_NAME(SIGBUS),  SIG_NAME(SIGSYS),
		SIG_NAME(SIGPIPE), SIG_NAME(SIGALRM), SIG_NAME(SIGURG),
		SIG_NAME(SIGSTOP), SIG_NAME(SIGTSTP), SIG_NAME(SIGCONT),
		SIG_NAME(SIGCHLD), SIG_NAME(SIGTTIN), SIG_NAME(SIGTTOU),
#ifndef __MACH__
		SIG_NAME(SIGPOLL),
#endif
		SIG_NAME(SIGXCPU), SIG_NAME(SIGXFSZ), SIG_NAME(SIGVTALRM),
		SIG_NAME(SIGPROF), SIG_NAME(SIGUSR1), SIG_NAME(SIGUSR2),
#endif
	};
	for (i = 0; i < sizeof(signals) / sizeof(signals[0]); i++) {
		lua_pushinteger(L, signals[i].signum);
		lua_setfield(L, -2, signals[i].name);
		lua_pushstring(L, signals[i].name);
		lua_seti(L, -2, signals[i].signum);
	}
	return 1;
#undef SIG_NAME
}

static int lsignal(lua_State *L)
{
	int signum = luaL_checkinteger(L, 1);
	int err = silly_signal_watch(signum);
	if (err != 0) {
		lua_pushstring(L, strerror(err));
	} else {
		lua_pushnil(L);
	}
	return 1;
}

SILLY_MOD_API int luaopen_silly_c(lua_State *L)
{
	luaL_Reg tbl[] = {
		{ "register",   lregister  },
		{ "signalmap",  lsignalmap },
		{ "signal",     lsignal    },
		{ "genid",      lgenid     },
		{ "tostring",   ltostring  },
		{ "exit",       lexit      },
		{ NULL,         NULL       },
	};

	luaL_newlib(L, tbl);
	// c.version
	lua_pushstring(L, SILLY_VERSION);
	lua_setfield(L, -2, "version");
	// c.gitsha1
	lua_pushstring(L, STR(SILLY_GIT_SHA1));
	lua_setfield(L, -2, "gitsha1");
	// c.timerresolution
	lua_pushinteger(L, TIMER_RESOLUTION);
	lua_setfield(L, -2, "timerresolution");
	// c.muxplexer
	lua_pushstring(L, silly_socket_multiplexer());
	lua_setfield(L, -2, "multiplexer");
	// c.memallocator
	lua_pushstring(L, silly_allocator());
	lua_setfield(L, -2, "allocator");
	// c.pid
	lua_pushinteger(L, getpid());
	lua_setfield(L, -2, "pid");
	return 1;
}