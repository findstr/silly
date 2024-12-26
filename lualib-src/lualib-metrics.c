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
#ifndef __WIN32
#include <sys/resource.h>
#endif
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>

#include "silly.h"
#include "compiler.h"
#include "silly_log.h"
#include "silly_run.h"
#include "silly_worker.h"
#include "silly_socket.h"
#include "silly_malloc.h"
#include "silly_timer.h"

#ifndef DISABLE_JEMALLOC
#include <jemalloc/jemalloc.h>
#endif

static int lmemallocator(lua_State *L)
{
	const char *ver;
	ver = silly_allocator();
	lua_pushstring(L, ver);
	return 1;
}

static int lcpustat(lua_State *L)
{
#ifndef __WIN32
	struct rusage ru;
	float stime, utime;
	getrusage(RUSAGE_SELF, &ru);
	stime = (float)ru.ru_stime.tv_sec;
	stime += (float)ru.ru_stime.tv_usec / 1000000;
	utime = (float)ru.ru_utime.tv_sec;
	utime += (float)ru.ru_utime.tv_usec / 1000000;
	lua_pushnumber(L, stime);
	lua_pushnumber(L, utime);
#else
	lua_pushnumber(L, 0);
	lua_pushnumber(L, 0);
#endif
	return 2;
}

static int lmaxfds(lua_State *L)
{
#ifndef __WIN32
	struct rlimit rlim;
	int ret = getrlimit(RLIMIT_NOFILE, &rlim);
	if (ret != 0) {
		silly_log_error("[metrics] getrlimit errno:%d", errno);
		rlim.rlim_cur = 0;
		rlim.rlim_max = 0;
	}
	lua_pushinteger(L, rlim.rlim_cur); //soft
	lua_pushinteger(L, rlim.rlim_max); //hard
#else
	lua_pushinteger(L, 0);
	lua_pushinteger(L, 0);
#endif
	return 2;
}

static int lopenfds(lua_State *L)
{
	int fd_count = 0;
#ifdef __linux__
	struct dirent *entry;
	DIR *fd_dir = opendir("/proc/self/fd");
	if (fd_dir == NULL) {
		silly_log_error("[metrics] failed to open /proc/self/fd");
		lua_pushinteger(L, 0);
		return 1;
	}
	while ((entry = readdir(fd_dir)) != NULL) {
		if (entry->d_name[0] != '.') {
			fd_count++;
		}
	}
	closedir(fd_dir);
#endif
	lua_pushinteger(L, fd_count);
	return 1;
}

static int lmemstat(lua_State *L)
{
	lua_pushinteger(L, silly_memrss());
	lua_pushinteger(L, silly_memused());
	return 2;
}

static int ljestat(lua_State *L)
{
	size_t allocated, active, resident, retained;
#ifndef DISABLE_JEMALLOC
	uint64_t epoch = 1;
	size_t sz = sizeof(epoch);
	je_mallctl("epoch", &epoch, &sz, &epoch, sz);
	sz = sizeof(size_t);
	je_mallctl("stats.resident", &resident, &sz, NULL, 0);
	je_mallctl("stats.active", &active, &sz, NULL, 0);
	je_mallctl("stats.allocated", &allocated, &sz, NULL, 0);
	je_mallctl("stats.retained", &retained, &sz, NULL, 0);
#else
	allocated = resident = active = retained = 0;
#endif
	lua_pushinteger(L, allocated);
	lua_pushinteger(L, active);
	lua_pushinteger(L, resident);
	lua_pushinteger(L, retained);
	return 4;
}

static int lworkerstat(lua_State *L)
{
	size_t sz;
	sz = silly_worker_msgsize();
	lua_pushinteger(L, sz);
	return 1;
}

static int lpollapi(lua_State *L)
{
	const char *api = silly_socket_pollapi();
	lua_pushstring(L, api);
	return 1;
}

static inline void table_set_int(lua_State *L, int table, const char *k, int v)
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
	struct silly_netstat *stat;
	stat = silly_socket_netstat();
	lua_pushinteger(L, stat->connecting);
	lua_pushinteger(L, stat->tcpclient);
	lua_pushinteger(L, silly_socket_ctrlcount());
	lua_pushinteger(L, stat->sendsize);
	lua_pushinteger(L, stat->recvsize);
	return 5;
}

static int ltimerstat(lua_State *L)
{
	uint32_t active, expired;
	active = silly_timer_info(&expired);
	lua_pushinteger(L, active);
	lua_pushinteger(L, expired);
	return 2;
}

static int lsocketstat(lua_State *L)
{
	int sid;
	struct silly_socketstat info;
	sid = luaL_checkinteger(L, 1);
	silly_socket_socketstat(sid, &info);
	lua_newtable(L);
	table_set_int(L, -1, "fd", info.sid);
	table_set_int(L, -1, "os_fd", info.fd);
	table_set_int(L, -1, "sendsize", info.sendsize);
	table_set_str(L, -1, "type", info.type);
	table_set_str(L, -1, "protocol", info.protocol);
	table_set_str(L, -1, "localaddr", info.localaddr);
	table_set_str(L, -1, "remoteaddr", info.remoteaddr);
	return 1;
}

static int ltimerresolution(lua_State *L)
{
	lua_pushinteger(L, TIMER_RESOLUTION);
	return 1;
}

int luaopen_core_metrics_c(lua_State *L)
{
	luaL_Reg tbl[] = {
		//build
		{ "pollapi",         lpollapi         },
		{ "memallocator",    lmemallocator    },
		{ "timerresolution", ltimerresolution },
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
		{ "socketstat",      lsocketstat      },
		//end
		{ NULL,              NULL             },
	};

	luaL_checkversion(L);
	luaL_newlib(L, tbl);
	return 1;
}
