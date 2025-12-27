#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <assert.h>
#include <stdlib.h>
#include <stdio.h>
#include <stddef.h>
#include <dirent.h>
#include <string.h>
#include <sys/time.h>
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>

#include "silly.h"

#ifndef DISABLE_JEMALLOC
#include <jemalloc/jemalloc.h>
#endif

static int lcpustat(lua_State *L)
{
	float stime, utime;
	silly_cpu_usage(&stime, &utime);
	lua_pushnumber(L, stime);
	lua_pushnumber(L, utime);
	return 2;
}

static int lmaxfds(lua_State *L)
{
	int soft, hard;
	silly_fd_open_limit(&soft, &hard);
	lua_pushinteger(L, soft);
	lua_pushinteger(L, hard);
	return 2;
}

static int lopenfds(lua_State *L)
{
	lua_pushinteger(L, silly_open_fd_count());
	return 1;
}

static int lmemstat(lua_State *L)
{
	lua_pushinteger(L, silly_rss_bytes());
	lua_pushinteger(L, silly_allocated_bytes());
	return 2;
}

static int ljestat(lua_State *L)
{
	size_t allocated, active, resident, retained;
	uint64_t epoch = 1;
	size_t sz = sizeof(epoch);
	silly_mallctl("epoch", &epoch, &sz, &epoch, sz);
	sz = sizeof(size_t);
	silly_mallctl("stats.resident", &resident, &sz, NULL, 0);
	silly_mallctl("stats.active", &active, &sz, NULL, 0);
	silly_mallctl("stats.allocated", &allocated, &sz, NULL, 0);
	silly_mallctl("stats.retained", &retained, &sz, NULL, 0);
	lua_pushinteger(L, allocated);
	lua_pushinteger(L, active);
	lua_pushinteger(L, resident);
	lua_pushinteger(L, retained);
	return 4;
}

static int lworkerstat(lua_State *L)
{
	size_t sz;
	sz = silly_worker_backlog();
	lua_pushinteger(L, sz);
	return 1;
}

static inline void table_set_int(lua_State *L, int table, const char *k,
				 lua_Integer v)
{
	lua_pushinteger(L, v);
	lua_setfield(L, table - 1, k);
}

static inline void table_set_str(lua_State *L, int table, const char *k,
				 const char *v)
{
	lua_pushstring(L, v);
	lua_setfield(L, table - 1, k);
}

static int lnetstat(lua_State *L)
{
	struct silly_netstat stat;
	silly_netstat(&stat);
	lua_pushinteger(L, stat.tcp_connections);
	lua_pushinteger(L, stat.sent_bytes);
	lua_pushinteger(L, stat.received_bytes);
	lua_pushinteger(L, stat.operate_request);
	lua_pushinteger(L, stat.operate_processed);
	return 5;
}

static int ltimerstat(lua_State *L)
{
	struct silly_timerstat stat;
	silly_timerstat(&stat);
	lua_pushinteger(L, stat.pending);
	lua_pushinteger(L, stat.scheduled);
	lua_pushinteger(L, stat.fired);
	lua_pushinteger(L, stat.canceled);
	return 4;
}

static int lsocketstat(lua_State *L)
{
	silly_socket_id_t sid;
	struct silly_socketstat info;
	sid = luaL_checkinteger(L, 1);
	silly_socketstat(sid, &info);
	lua_newtable(L);
	table_set_int(L, -1, "fd", info.sid);
	table_set_int(L, -1, "os_fd", info.fd);
	table_set_int(L, -1, "sent_bytes", info.sent_bytes);
	table_set_str(L, -1, "type", info.type);
	table_set_str(L, -1, "protocol", info.protocol);
	table_set_str(L, -1, "localaddr", info.localaddr);
	table_set_str(L, -1, "remoteaddr", info.remoteaddr);
	return 1;
}

SILLY_MOD_API int luaopen_silly_metrics_c(lua_State *L)
{
	luaL_Reg tbl[] = {
		//process
		{ "cpustat",         lcpustat         },
		{ "maxfds",          lmaxfds          },
		{ "openfds",         lopenfds         },
		//memory
		{ "memstat",         lmemstat         },
		{ "jestat",          ljestat          },
		//core
		{ "workerstat",      lworkerstat      },
		{ "timerstat",       ltimerstat       },
		{ "netstat",         lnetstat         },
		{ "socketstat",        lsocketstat      },
		//end
		{ NULL,              NULL             },
	};

	luaL_checkversion(L);
	luaL_newlib(L, tbl);
	return 1;
}