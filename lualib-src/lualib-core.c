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
#include "compiler.h"
#include "silly_trace.h"
#include "silly_log.h"
#include "silly_run.h"
#include "silly_worker.h"
#include "silly_socket.h"
#include "silly_malloc.h"
#include "silly_timer.h"
#include "silly_signal.h"

static void dispatch(lua_State *L, struct silly_message *sm)
{
	int type;
	int err;
	int args = 1;
	const char *addr;
	size_t addrlen;
	type = lua_rawgetp(L, LUA_REGISTRYINDEX, dispatch);
	if (unlikely(type != LUA_TFUNCTION)) {
		silly_log_error("[silly.core] callback need function"
				"but got:%s\n",
				lua_typename(L, type));
		return;
	}
	lua_pushinteger(L, sm->type);
	switch (sm->type) {
	case SILLY_TEXPIRE:
		lua_pushinteger(L, totexpire(sm)->session);
		lua_pushinteger(L, totexpire(sm)->userdata);
		args += 2;
		break;
	case SILLY_SACCEPT:
		addrlen = *tosocket(sm)->data;
		addr = (char *)tosocket(sm)->data + 1;
		lua_pushinteger(L, tosocket(sm)->sid);
		lua_pushlightuserdata(L, sm);
		lua_pushinteger(L, tosocket(sm)->ud);
		lua_pushlstring(L, addr, addrlen);
		args += 4;
		break;
	case SILLY_SCONNECTED:
		lua_pushinteger(L, tosocket(sm)->sid);
		lua_pushlightuserdata(L, sm);
		args += 2;
		break;
	case SILLY_SDATA:
		lua_pushinteger(L, tosocket(sm)->sid);
		lua_pushlightuserdata(L, sm);
		args += 2;
		break;
	case SILLY_SUDP:
		addr = (char *)tosocket(sm)->data + tosocket(sm)->ud;
		addrlen = silly_socket_salen(addr);
		lua_pushinteger(L, tosocket(sm)->sid);
		lua_pushlightuserdata(L, sm);
		lua_pushlstring(L, addr, addrlen);
		args += 3;
		break;
	case SILLY_SCLOSE:
		lua_pushinteger(L, tosocket(sm)->sid);
		lua_pushlightuserdata(L, sm);
		lua_pushinteger(L, tosocket(sm)->ud);
		args += 3;
		break;
	case SILLY_SIGNAL:
		lua_pushinteger(L, tosignal(sm)->signum);
		args += 1;
		break;
	default:
		silly_log_error(
			"[silly.core] callback unknow message type:%d\n",
			sm->type);
		assert(0);
		break;
	}
	/*the first stack slot of main thread is always trace function */
	err = lua_pcall(L, args, 0, 1);
	if (unlikely(err != LUA_OK)) {
		silly_log_error("[silly.core] callback call fail:%d:%s\n", err,
				lua_tostring(L, -1));
		lua_pop(L, 1);
	}
	return;
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
	uint32_t id = silly_worker_genid();
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

static int ldispatch(lua_State *L)
{
	lua_pushlightuserdata(L, dispatch);
	lua_insert(L, -2);
	lua_settable(L, LUA_REGISTRYINDEX);
	return 0;
}

static int ltimeout(lua_State *L)
{
	uint32_t expire;
	uint32_t userdata;
	uint64_t session;
	expire = luaL_checkinteger(L, 1);
	userdata = luaL_optinteger(L, 2, 0);
	session = silly_timer_timeout(expire, userdata);
	lua_pushinteger(L, (lua_Integer)session);
	return 1;
}

static int ltimercancel(lua_State *L)
{
	uint32_t ud;
	uint64_t session = (uint64_t)luaL_checkinteger(L, 1);
	int ok = silly_timer_cancel(session, &ud);
	if (ok) {
		lua_pushinteger(L, ud);
	} else {
		lua_pushnil(L);
	}
	return 1;
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

//socket
struct multicasthdr {
	uint32_t ref;
	char mask;
	uint8_t data[1];
};

#define MULTICAST_SIZE offsetof(struct multicasthdr, data)

//NOTE:this function may cocurrent
static void multifinalizer(void *buff)
{
	struct multicasthdr *hdr;
	uint8_t *ptr = (uint8_t *)buff;
	hdr = (struct multicasthdr *)(ptr - MULTICAST_SIZE);
	assert(hdr->mask == 'M');
	uint32_t refcount = __sync_sub_and_fetch(&hdr->ref, 1);
	if (refcount == 0)
		silly_free(hdr);
	return;
}

static int lmultipack(lua_State *L)
{
	size_t size;
	uint8_t *buf;
	int refcount;
	int stk, type;
	struct multicasthdr *hdr;
	type = lua_type(L, 1);
	if (type == LUA_TSTRING) {
		stk = 2;
		buf = (uint8_t *)lua_tolstring(L, 1, &size);
	} else {
		stk = 3;
		buf = lua_touserdata(L, 1);
		size = luaL_checkinteger(L, 2);
	}
	refcount = luaL_checkinteger(L, stk);
	hdr = (struct multicasthdr *)silly_malloc(size + MULTICAST_SIZE);
	memcpy(hdr->data, buf, size);
	if (type != LUA_TSTRING)
		silly_free(buf);
	hdr->mask = 'M';
	hdr->ref = refcount;
	lua_pushlightuserdata(L, &hdr->data);
	lua_pushinteger(L, size);
	return 2;
}

static int lmultifree(lua_State *L)
{
	uint8_t *buf = lua_touserdata(L, 1);
	multifinalizer(buf);
	return 0;
}

static inline void *stringbuffer(lua_State *L, int idx, size_t *size)
{
	size_t sz;
	const char *str = lua_tolstring(L, idx, &sz);
	char *p = silly_malloc(sz);
	memcpy(p, str, sz);
	*size = sz;
	return p;
}

static inline void *udatabuffer(lua_State *L, int idx, size_t *size)
{
	*size = luaL_checkinteger(L, idx + 1);
	return lua_touserdata(L, idx);
}

static inline void *tablebuffer(lua_State *L, int idx, size_t *size)
{
	int i;
	const char *str;
	char *p, *current;
	size_t total = 0;
	for (i = 1; lua_rawgeti(L, idx, i) != LUA_TNIL; i++) {
		size_t n;
		luaL_checklstring(L, -1, &n);
		total += n;
		lua_pop(L, 1);
	}
	lua_pop(L, 1);
	current = p = silly_malloc(total);
	for (i = 1; lua_rawgeti(L, idx, i) != LUA_TNIL; i++) {
		size_t n;
		str = lua_tolstring(L, -1, &n);
		memcpy(current, str, n);
		current += n;
		lua_pop(L, 1);
	}
	lua_pop(L, 1);
	*size = total;
	return p;
}

typedef int(connect_t)(const char *ip, const char *port, const char *bip,
		       const char *bport);

static int socketconnect(lua_State *L, connect_t *connect)
{
	int fd;
	const char *ip;
	const char *port;
	const char *bip;
	const char *bport;
	ip = luaL_checkstring(L, 1);
	port = luaL_checkstring(L, 2);
	bip = luaL_checkstring(L, 3);
	bport = luaL_checkstring(L, 4);
	fd = connect(ip, port, bip, bport);
	if (unlikely(fd < 0)) {
		lua_pushnil(L);
		lua_pushstring(L, silly_socket_lasterror());
	} else {
		lua_pushinteger(L, fd);
		lua_pushnil(L);
	}
	return 2;
}

static int ltcpconnect(lua_State *L)
{
	return socketconnect(L, silly_socket_connect);
}

static int ltcplisten(lua_State *L)
{
	const char *ip = luaL_checkstring(L, 1);
	const char *port = luaL_checkstring(L, 2);
	int backlog = (int)luaL_checkinteger(L, 3);
	int fd = silly_socket_listen(ip, port, backlog);
	if (unlikely(fd < 0)) {
		lua_pushnil(L);
		lua_pushstring(L, silly_socket_lasterror());
	} else {
		lua_pushinteger(L, fd);
		lua_pushnil(L);
	}
	return 2;
}

static int ltcpsend(lua_State *L)
{
	int err;
	int sid;
	size_t size;
	uint8_t *buff;
	sid = luaL_checkinteger(L, 1);
	int type = lua_type(L, 2);
	switch (type) {
	case LUA_TSTRING:
		buff = stringbuffer(L, 2, &size);
		break;
	case LUA_TLIGHTUSERDATA:
		buff = udatabuffer(L, 2, &size);
		break;
	case LUA_TTABLE:
		buff = tablebuffer(L, 2, &size);
		break;
	default:
		return luaL_error(L, "netstream.pack unsupport:%s",
				  lua_typename(L, 2));
	}
	err = silly_socket_send(sid, buff, size, NULL);
	lua_pushboolean(L, err < 0 ? 0 : 1);
	return 1;
}

static int ltcpmulticast(lua_State *L)
{
	int err;
	int sid;
	uint8_t *buff;
	int size;
	sid = luaL_checkinteger(L, 1);
	buff = lua_touserdata(L, 2);
	size = luaL_checkinteger(L, 3);
	err = silly_socket_send(sid, buff, size, multifinalizer);
	lua_pushboolean(L, err < 0 ? 0 : 1);
	return 1;
}

static int ludpconnect(lua_State *L)
{
	return socketconnect(L, silly_socket_udpconnect);
}

static int ludpbind(lua_State *L)
{
	const char *ip = luaL_checkstring(L, 1);
	const char *port = luaL_checkstring(L, 2);
	int fd = silly_socket_udpbind(ip, port);
	if (unlikely(fd < 0)) {
		lua_pushnil(L);
		lua_pushstring(L, silly_socket_lasterror());
	} else {
		lua_pushinteger(L, fd);
		lua_pushnil(L);
	}
	return 2;
}

static int ludpsend(lua_State *L)
{
	int idx;
	int err;
	int sid;
	size_t size;
	uint8_t *buff;
	const uint8_t *addr = NULL;
	size_t addrlen = 0;
	sid = luaL_checkinteger(L, 1);
	int type = lua_type(L, 2);
	switch (type) {
	case LUA_TSTRING:
		idx = 3;
		buff = stringbuffer(L, 2, &size);
		break;
	case LUA_TLIGHTUSERDATA:
		idx = 4;
		buff = udatabuffer(L, 2, &size);
		break;
	case LUA_TTABLE:
		idx = 3;
		buff = tablebuffer(L, 2, &size);
		break;
	default:
		return luaL_error(L, "netstream.pack unsupport:%s",
				  lua_typename(L, 2));
	}
	if (!lua_isnoneornil(L, idx))
		addr = (const uint8_t *)luaL_checklstring(L, idx, &addrlen);
	err = silly_socket_udpsend(sid, buff, size, addr, addrlen, NULL);
	lua_pushboolean(L, err < 0 ? 0 : 1);
	return 1;
}

static int lntop(lua_State *L)
{
	int size;
	const char *addr;
	char name[SOCKET_NAMELEN];
	addr = luaL_checkstring(L, 1);
	size = silly_socket_ntop((uint8_t *)addr, name);
	lua_pushlstring(L, name, size);
	return 1;
}

static int lclose(lua_State *L)
{
	int err;
	int sid;
	sid = luaL_checkinteger(L, 1);
	err = silly_socket_close(sid);
	lua_pushboolean(L, err < 0 ? 0 : 1);
	return 1;
}

static int lreadctrl(lua_State *L)
{
	int sid = luaL_checkinteger(L, 1);
	int ctrl = lua_toboolean(L, 2);
	silly_socket_readctrl(sid, ctrl);
	return 0;
}

static int lsendsize(lua_State *L)
{
	int sid = luaL_checkinteger(L, 1);
	int size = silly_socket_sendsize(sid);
	lua_pushinteger(L, size);
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
	silly_worker_resume(co);
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

int luaopen_core_c(lua_State *L)
{
	luaL_Reg tbl[] = {
		//core
		{ "gitsha1",       lgitsha1      },
		{ "version",       lversion      },
		{ "dispatch",      ldispatch     },
		{ "timeout",       ltimeout      },
		{ "timercancel",   ltimercancel  },
		{ "signalmap",     lsignalmap    },
		{ "signal",        lsignal       },
		{ "genid",         lgenid        },
		{ "tostring",      ltostring     },
		{ "getpid",        lgetpid       },
		{ "strerror",      lstrerror     },
		{ "exit",          lexit         },
		//trace
		{ "trace_span",    ltracespan    },
		{ "trace_new",     ltracenew     },
		{ "trace_set",     ltraceset     },
		{ "trace_get",     ltraceget     },
		//socket
		{ "tcp_connect",   ltcpconnect   },
		{ "tcp_listen",    ltcplisten    },
		{ "tcp_send",      ltcpsend      },
		{ "tcp_multicast", ltcpmulticast },
		{ "udp_bind",      ludpbind      },
		{ "udp_connect",   ludpconnect   },
		{ "udp_send",      ludpsend      },
		{ "sendsize",      lsendsize     },
		{ "multipack",     lmultipack    },
		{ "multifree",     lmultifree    },
		{ "readctrl",      lreadctrl     },
		{ "ntop",          lntop         },
		{ "close",         lclose        },
		//end
		{ NULL,            NULL          },
	};

	luaL_checkversion(L);
	lua_rawgeti(L, LUA_REGISTRYINDEX, LUA_RIDX_MAINTHREAD);
	lua_State *m = lua_tothread(L, -1);
	lua_pop(L, 1);

	lua_pushlightuserdata(L, (void *)m);
	lua_gettable(L, LUA_REGISTRYINDEX);
	silly_worker_callback(dispatch);
	luaL_newlibtable(L, tbl);
	luaL_setfuncs(L, tbl, 0);

	return 1;
}
