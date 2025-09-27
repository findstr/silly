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

#define UPVAL_ERROR_TABLE (1)

static inline void push_error(lua_State *L, int code)
{
	silly_push_error(L, lua_upvalueindex(UPVAL_ERROR_TABLE), code);
}

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

static int lgetpid(lua_State *L)
{
	int pid = getpid();
	lua_pushinteger(L, pid);
	return 1;
}

static int lstrerror(lua_State *L)
{
	lua_Integer err = luaL_checkinteger(L, 1);
	lua_pushstring(L, strerror((int)err));
	return 1;
}

static int lgitsha1(lua_State *L)
{
	lua_pushstring(L, STR(SILLY_GIT_SHA1));
	return 1;
}

static int lversion(lua_State *L)
{
	const char *ver = SILLY_VERSION;
	lua_pushstring(L, ver);
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

static int ltracespan(lua_State *L)
{
	silly_tracespan_t span;
	span = (silly_tracespan_t)luaL_checkinteger(L, 1);
	silly_trace_span(span);
	return 0;
}

static int ltracenew(lua_State *L)
{
	silly_traceid_t traceid;
	traceid = silly_trace_new();
	lua_pushinteger(L, (lua_Integer)traceid);
	return 1;
}

static int ltraceset(lua_State *L)
{
	silly_traceid_t traceid;
	lua_State *co = lua_tothread(L, 1);
	silly_resume(co);
	if lua_isnoneornil (L, 2) {
		traceid = TRACE_WORKER_ID;
	} else {
		traceid = (silly_traceid_t)luaL_checkinteger(L, 2);
	}
	traceid = silly_trace_set(traceid);
	lua_pushinteger(L, (lua_Integer)traceid);
	return 1;
}

static int ltraceget(lua_State *L)
{
	silly_traceid_t traceid;
	traceid = silly_trace_get();
	lua_pushinteger(L, (lua_Integer)traceid);
	return 1;
}

SILLY_MOD_API int luaopen_core_c(lua_State *L)
{
	luaL_Reg tbl[] = {
		//core
		{ "gitsha1",    lgitsha1   },
		{ "version",    lversion   },
		{ "register",   lregister  },
		{ "signalmap",  lsignalmap },
		{ "signal",     lsignal    },
		{ "genid",      lgenid     },
		{ "tostring",   ltostring  },
		{ "getpid",     lgetpid    },
		{ "strerror",   lstrerror  },
		{ "exit",       lexit      },
		//trace
		{ "trace_span", ltracespan },
		{ "trace_new",  ltracenew  },
		{ "trace_set",  ltraceset  },
		{ "trace_get",  ltraceget  },
		//end
		{ NULL,         NULL       },
	};

	luaL_checkversion(L);
	luaL_newlibtable(L, tbl);
	silly_error_table(L);
	luaL_setfuncs(L, tbl, 1);
	return 1;
}