#include <unistd.h>
#include <assert.h>
#include <errno.h>
#include <signal.h>
#include <stdlib.h>
#include <stdio.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <sys/time.h>
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>

#include "silly.h"

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

SILLY_MOD_API int luaopen_silly_signal_c(lua_State *L)
{
	luaL_Reg tbl[] = {
		{ "signalmap", lsignalmap },
		{ "signal",    lsignal    },
		{ NULL,        NULL       },
	};

	luaL_checkversion(L);
	luaL_newlib(L, tbl);
	lua_pushinteger(L, silly_messages()->signal_fire);
	lua_setfield(L, -2, "FIRE");
	return 1;
}
