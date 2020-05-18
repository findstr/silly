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
#include "silly_env.h"
#include "silly_run.h"
#include "silly_worker.h"
#include "silly_socket.h"
#include "silly_malloc.h"
#include "silly_timer.h"

static void
dispatch(lua_State *L, struct silly_message *sm)
{
	int type;
	int err;
	int args = 1;
	const char *addr;
	size_t addrlen;
	lua_pushlightuserdata(L, dispatch);
	type = lua_gettable(L, LUA_REGISTRYINDEX);
	if (unlikely(type != LUA_TFUNCTION)) {
		silly_log("[silly.core] callback need function"
			"but got:%s\n", lua_typename(L, type));
		return ;
	}
	lua_pushinteger(L, sm->type);
	switch (sm->type) {
	case SILLY_TEXPIRE:
		lua_pushinteger(L, totexpire(sm)->session);
		lua_pushlightuserdata(L, sm);
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
	default:
		silly_log("[silly.core] callback unknow message type:%d\n",
			sm->type);
		assert(0);
		break;
	}
	err = lua_pcall(L, args, 0, 0);
	if (unlikely(err != LUA_OK)) {
		silly_log("[silly.core] callback call fail:%s\n",
			lua_tostring(L, -1));
		lua_pop(L, 1);
	}
	return ;
}



static int
lgetenv(lua_State *L)
{
	const char *key = luaL_checkstring(L, 1);
	const char *value = silly_env_get(key);
	if (value)
		lua_pushstring(L, value);
	else
		lua_pushnil(L);

	return 1;
}

static int
lsetenv(lua_State *L)
{
	const char *key = luaL_checkstring(L, 1);
	const char *value = luaL_checkstring(L, 2);
	silly_env_set(key, value);
	return 0;
}

static int
lexit(lua_State *L)
{
	int status;
	status = luaL_optinteger(L, 1, 0);
	silly_exit(status);
	return 0;
}

static char *
inttostr(lua_Integer n, char *begin, char *end)
{
	int neg = 0;
	if (n < 0) {
		neg = 1;
		n = -n;
	}
	do {
		int m = n % 10;
		n /= 10;
		*(--end) = m + '0';
	} while (begin < end && n > 0);
	if (neg && begin < end)
		*(--end) = '-';
	return end;
}

static int
llog(lua_State *L)
{
	int i;
	size_t sz;
	const char *str;
	int paramn = lua_gettop(L);
	silly_log("");
	for (i = 1; i <= paramn; i++) {
		int type = lua_type(L, i);
		switch (type) {
		case LUA_TSTRING:
			str = lua_tolstring(L, i, &sz);
			silly_log_lstr(str, sz);
			silly_log_lstr(" ", 1);
			break;
		case LUA_TNUMBER:
			if (lua_isinteger(L, i)) {
				char buf[32];
				lua_Integer n = lua_tointeger(L, i);
				char *end = &buf[sizeof(buf)/sizeof(buf[0])];
				char *start = end - 1;
				*start = ' ';
				start = inttostr(n, buf, start);
				silly_log_lstr(start, end - start);
			} else {
				lua_Number n = lua_tonumber(L, i);
				silly_log_raw(LUA_NUMBER_FMT" ", n);
			}
			break;
		case LUA_TBOOLEAN:
			if (lua_toboolean(L, i))
				silly_log_str("true ");
			else
				silly_log_str("false ");
			break;
		case LUA_TTABLE:
			silly_log_raw("table: %p ", lua_topointer(L, i));
			break;
		case LUA_TNIL:
			silly_log_str("nil ");
			break;
		default:
			return luaL_error(L, "log unspport param#%d type:%s",
				i, lua_typename(L, type));
		}
	}
	silly_log_str("\n");
	return 0;
}

static int
lgenid(lua_State *L)
{
	uint32_t id = silly_worker_genid();
	lua_pushinteger(L, id);
	return 1;
}

static int
ltostring(lua_State *L)
{
	char *buff;
	int size;
	buff = lua_touserdata(L, 1);
	size = luaL_checkinteger(L, 2);
	lua_pushlstring(L, buff, size);
	return 1;
}

static int
lgetpid(lua_State *L)
{
	int pid = getpid();
	lua_pushinteger(L, pid);
	return 1;
}

static int
ltimeout(lua_State *L)
{
	uint32_t expire;
	uint32_t session;
	expire = luaL_checkinteger(L, 1);
	session = silly_timer_timeout(expire);
	lua_pushinteger(L, session);
	return 1;
}

static int
ltimenow(lua_State *L)
{
	uint64_t now = silly_timer_now();
	lua_pushinteger(L, now);
	return 1;
}

static int
ltimenowsec(lua_State *L)
{
	uint64_t now = silly_timer_nowsec();
	lua_pushinteger(L, now);
	return 1;
}

static int
ltimemonotonic(lua_State *L)
{
	uint64_t monotonic = silly_timer_monotonic();
	lua_pushinteger(L, monotonic);
	return 1;
}

static int
ltimemonotonicsec(lua_State *L)
{
	uint64_t monotonic = silly_timer_monotonicsec();
	lua_pushinteger(L, monotonic);
	return 1;
}

static int
ldispatch(lua_State *L)
{
	lua_pushlightuserdata(L, dispatch);
	lua_insert(L, -2);
	lua_settable(L, LUA_REGISTRYINDEX);
	return 0;
}

typedef int (connect_t)(const char *ip, const char *port,
		const char *bip, const char *bport);

static int
socketconnect(lua_State *L, connect_t *connect)
{
	int err;
	const char *ip;
	const char *port;
	const char *bip;
	const char *bport;
	ip = luaL_checkstring(L, 1);
	port = luaL_checkstring(L, 2);
	bip = luaL_checkstring(L, 3);
	bport = luaL_checkstring(L, 4);
	err = connect(ip, port, bip, bport);
	lua_pushinteger(L, err);
	return 1;
}

static int
ltcpconnect(lua_State *L)
{
	return socketconnect(L, silly_socket_connect);
}

static int
ltcplisten(lua_State *L)
{
	const char *ip = luaL_checkstring(L, 1);
	const char *port = luaL_checkstring(L, 2);
	int backlog = luaL_checkinteger(L, 3);
	int err = silly_socket_listen(ip, port, backlog);
	lua_pushinteger(L, err);
	return 1;
}

//NOTE:this function may cocurrent

struct multicasthdr {
	uint32_t ref;
	char mask;
	uint8_t data[1];
};

#define	MULTICAST_SIZE offsetof(struct multicasthdr, data)

static void
multifinalizer(void *buff)
{
	struct multicasthdr *hdr;
	uint8_t *ptr = (uint8_t *)buff;
	hdr = (struct multicasthdr *)(ptr - MULTICAST_SIZE);
	assert(hdr->mask == 'M');
	uint32_t refcount = __sync_sub_and_fetch(&hdr->ref, 1);
	if (refcount == 0)
		silly_free(hdr);
	return ;
}

static int
lmultipack(lua_State *L)
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

static int
lmultifree(lua_State *L)
{
	uint8_t *buf = lua_touserdata(L, 1);
	multifinalizer(buf);
	return 0;
}

static inline void *
stringbuffer(lua_State *L, int idx, size_t *size)
{
	size_t sz;
	const char *str = lua_tolstring(L, idx, &sz);
	char *p = silly_malloc(sz);
	memcpy(p, str, sz);
	*size = sz;
	return p;
}

static inline void *
udatabuffer(lua_State *L, int idx, size_t *size)
{
	*size = luaL_checkinteger(L, idx + 1);
	return lua_touserdata(L, idx);
}

static inline void *
tablebuffer(lua_State *L, int idx, size_t *size)
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

static int
ltcpsend(lua_State *L)
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

static int
ltcpmulticast(lua_State *L)
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

static int
ludpconnect(lua_State *L)
{
	return socketconnect(L, silly_socket_udpconnect);
}

static int
ludpbind(lua_State *L)
{
	const char *ip = luaL_checkstring(L, 1);
	const char *port = luaL_checkstring(L, 2);
	int err = silly_socket_udpbind(ip, port);
	lua_pushinteger(L, err);
	return 1;
}

static int
ludpsend(lua_State *L)
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

static int
lntop(lua_State *L)
{
	int size;
	const char *addr;
	char name[SOCKET_NAMELEN];
	addr = luaL_checkstring(L, 1);
	size = silly_socket_ntop((uint8_t *)addr, name);
	lua_pushlstring(L, name, size);
	return 1;
}

static int
lclose(lua_State *L)
{
	int err;
	int sid;
	sid = luaL_checkinteger(L, 1);
	err = silly_socket_close(sid);
	lua_pushboolean(L, err < 0 ? 0 : 1);
	return 1;
}

static int
lreadctrl(lua_State *L)
{
	int sid = luaL_checkinteger(L, 1);
	int ctrl = lua_toboolean(L, 2);
	silly_socket_readctrl(sid, ctrl);
	return 0;
}

static int
lsendsize(lua_State *L)
{
	int sid = luaL_checkinteger(L, 1);
	int size = silly_socket_sendsize(sid);
	lua_pushinteger(L, size);
	return 1;
}

static int
lversion(lua_State *L)
{
	const char *ver = SILLY_VERSION;
	lua_pushstring(L, ver);
	return 1;
}

static int
lmemallocator(lua_State *L)
{
	const char *ver;
	ver = silly_allocator();
	lua_pushstring(L, ver);
	return 1;
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
luaopen_sys_silly(lua_State *L)
{
	luaL_Reg tbl[] = {
		//core
		{"dispatch", ldispatch},
		{"getenv", lgetenv},
		{"setenv", lsetenv},
		{"exit", lexit},
		{"log", llog},
		{"genid", lgenid},
		{"tostring", ltostring},
		{"getpid", lgetpid},
		//timer
		{"timeout", ltimeout},
		{"timenow", ltimenow},
		{"timenowsec", ltimenowsec},
		{"timemonotonic", ltimemonotonic},
		{"timemonotonicsec", ltimemonotonicsec},
		//socket
		{"connect", ltcpconnect},
		{"listen", ltcplisten},
		{"multipack", lmultipack},
		{"multifree", lmultifree},
		{"send", ltcpsend},
		{"multicast", ltcpmulticast},
		{"bind", ludpbind},
		{"udp", ludpconnect},
		{"udpsend", ludpsend},
		{"ntop", lntop},
		{"close", lclose},
		{"readctrl", lreadctrl},
		{"sendsize", lsendsize},
		//probe
		{"version", lversion},
		{"memused", lmemused},
		{"memrss", lmemrss},
		{"memallocator", lmemallocator},
		{"msgsize", lmsgsize},
		{"cpuinfo", lcpuinfo},
		{"pollapi", lpollapi},
		{"netinfo", lnetinfo},
		{"socketinfo", lsocketinfo},
		{"timerresolution", ltimerresolution},
		//end
		{NULL, NULL},
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

