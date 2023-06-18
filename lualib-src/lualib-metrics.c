#include <unistd.h>
#include <assert.h>
#include <stdlib.h>
#include <stdio.h>
#include <stddef.h>
#include <string.h>
#include <sys/time.h>
#include <sys/resource.h>
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

static int
lmemallocator(lua_State *L)
{
	const char *ver;
	ver = silly_allocator();
	lua_pushstring(L, ver);
	return 1;
}

static int
lmemallocatorinfo(lua_State *L)
{
	size_t allocated, active, resident;
	silly_allocator_info(&allocated, &active, &resident);
	lua_pushinteger(L, allocated);
	lua_pushinteger(L, active);
	lua_pushinteger(L, resident);
	return 3;
}
static int
lmemused(lua_State *L)
{
	size_t sz;
	sz = silly_memused();
	lua_pushinteger(L, sz);
	return 1;
}

static int
lmemrss(lua_State *L)
{
	size_t sz;
	sz = silly_memrss();
	lua_pushinteger(L, sz);
	return 1;
}

static int
lmsgsize(lua_State *L)
{
	size_t sz;
	sz = silly_worker_msgsize();
	lua_pushinteger(L, sz);
	return 1;
}

static int
lcpuinfo(lua_State *L)
{
	struct rusage ru;
	float stime,utime;
	getrusage(RUSAGE_SELF, &ru);
	stime = (float)ru.ru_stime.tv_sec;
	stime += (float)ru.ru_stime.tv_usec / 1000000;
	utime = (float)ru.ru_utime.tv_sec;
	utime += (float)ru.ru_utime.tv_usec / 1000000;
	lua_pushnumber(L, stime);
	lua_pushnumber(L, utime);
	return 2;
}

static int
lpollapi(lua_State *L)
{
	const char *api = silly_socket_pollapi();
	lua_pushstring(L, api);
	return 1;
}

static inline void
table_set_int(lua_State *L, int table, const char *k, int v)
{
	lua_pushinteger(L, v);
	lua_setfield(L, table-1, k);
}

static inline void
table_set_str(lua_State *L, int table, const char *k, const char *v)
{
	lua_pushstring(L, v);
	lua_setfield(L, table-1, k);
}

static int
lnetinfo(lua_State *L)
{
	struct silly_netinfo info;
	silly_socket_netinfo(&info);
	lua_newtable(L);
	table_set_int(L, -1, "tcplisten", info.tcplisten);
	table_set_int(L, -1, "udpbind", info.udpbind);
	table_set_int(L, -1, "connecting", info.connecting);
	table_set_int(L, -1, "udpclient", info.udpclient);
	table_set_int(L, -1, "tcpclient", info.tcpclient);
	table_set_int(L, -1, "tcphalfclose", info.tcphalfclose);
	table_set_int(L, -1, "sendsize", info.sendsize);
	return 1;
}

static int
ltimerinfo(lua_State *L)
{
	uint32_t active, expired;
	active = silly_timer_info(&expired);
	lua_pushinteger(L, active);
	lua_pushinteger(L, expired);
	return 2;
}

static int
lsocketinfo(lua_State *L)
{
	int sid;
	struct silly_socketinfo info;
	sid = luaL_checkinteger(L, 1);
	silly_socket_socketinfo(sid, &info);
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

static int
ltimerresolution(lua_State *L)
{
	lua_pushinteger(L, TIMER_RESOLUTION);
	return 1;
}

int
luaopen_sys_metrics(lua_State *L)
{
	luaL_Reg tbl[] = {
		{"memused", lmemused},
		{"memrss", lmemrss},
		{"memallocator", lmemallocator},
		{"memallocatorinfo", lmemallocatorinfo},
		{"msgsize", lmsgsize},
		{"cpuinfo", lcpuinfo},
		{"pollapi", lpollapi},
		{"netinfo", lnetinfo},
		{"timerinfo", ltimerinfo},
		{"socketinfo", lsocketinfo},
		{"timerresolution", ltimerresolution},
		//end
		{NULL, NULL},
	};

	luaL_checkversion(L);
	luaL_newlib(L, tbl);
	return 1;
}

