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
#define MULTICAST_SIZE offsetof(struct multicasthdr, data)

struct multicasthdr {
	uint32_t ref;
	char mask;
	uint8_t data[1];
};

static inline void push_error(lua_State *L, int code)
{
	silly_push_error(L, lua_upvalueindex(UPVAL_ERROR_TABLE), code);
}

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

typedef silly_socket_id_t(connect_t)(const char *ip, const char *port,
				     const char *bip, const char *bport);

static int socketconnect(lua_State *L, connect_t *connect)
{
	silly_socket_id_t fd;
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
		push_error(L, -fd);
	} else {
		lua_pushinteger(L, fd);
		lua_pushnil(L);
	}
	return 2;
}

static int ltcpconnect(lua_State *L)
{
	return socketconnect(L, silly_tcp_connect);
}

static int ltcplisten(lua_State *L)
{
	const char *ip = luaL_checkstring(L, 1);
	const char *port = luaL_checkstring(L, 2);
	int backlog = (int)luaL_checkinteger(L, 3);
	silly_socket_id_t fd = silly_tcp_listen(ip, port, backlog);
	if (unlikely(fd < 0)) {
		lua_pushnil(L);
		push_error(L, -fd);
	} else {
		lua_pushinteger(L, fd);
		lua_pushnil(L);
	}
	return 2;
}

static int ltcpsend(lua_State *L)
{
	int err;
	silly_socket_id_t sid;
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
	err = silly_tcp_send(sid, buff, size, NULL);
	if (err < 0) {
		lua_pushboolean(L, 0);
		push_error(L, -err);
	} else {
		lua_pushboolean(L, 1);
		lua_pushnil(L);
	}
	return 2;
}

static int ltcpmulticast(lua_State *L)
{
	int err;
	silly_socket_id_t sid;
	uint8_t *buff;
	int size;
	sid = luaL_checkinteger(L, 1);
	buff = lua_touserdata(L, 2);
	size = luaL_checkinteger(L, 3);
	err = silly_tcp_send(sid, buff, size, multifinalizer);
	if (err < 0) {
		lua_pushboolean(L, 0);
		push_error(L, -err);
	} else {
		lua_pushboolean(L, 1);
		lua_pushnil(L);
	}
	return 2;
}

static int ludpconnect(lua_State *L)
{
	return socketconnect(L, silly_udp_connect);
}

static int ludpbind(lua_State *L)
{
	const char *ip = luaL_checkstring(L, 1);
	const char *port = luaL_checkstring(L, 2);
	silly_socket_id_t fd = silly_udp_bind(ip, port);
	if (unlikely(fd < 0)) {
		lua_pushnil(L);
		push_error(L, -fd);
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
	silly_socket_id_t sid;
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
	err = silly_udp_send(sid, buff, size, addr, addrlen, NULL);
	if (err < 0) {
		lua_pushboolean(L, 0);
		push_error(L, -err);
	} else {
		lua_pushboolean(L, 1);
		lua_pushnil(L);
	}
	return 2;
}

static int lntop(lua_State *L)
{
	int size;
	const char *addr;
	char name[SILLY_SOCKET_NAMELEN];
	addr = luaL_checkstring(L, 1);
	size = silly_ntop((void *)addr, name);
	lua_pushlstring(L, name, size);
	return 1;
}

static int lclose(lua_State *L)
{
	int err;
	silly_socket_id_t sid;
	sid = luaL_checkinteger(L, 1);
	err = silly_socket_close(sid);
	if (err < 0) {
		lua_pushboolean(L, 0);
		push_error(L, -err);
	} else {
		lua_pushboolean(L, 1);
		lua_pushnil(L);
	}
	return 2;
}

static int lreadenable(lua_State *L)
{
	silly_socket_id_t sid = luaL_checkinteger(L, 1);
	int enable = lua_toboolean(L, 2);
	silly_socket_readenable(sid, enable);
	return 0;
}

static int lsendsize(lua_State *L)
{
	silly_socket_id_t sid = luaL_checkinteger(L, 1);
	int size = silly_socket_sendsize(sid);
	lua_pushinteger(L, size);
	return 1;
}

static void set_message_type(lua_State *L, int tbl)
{
	const struct silly_message_id *msg_id = silly_messages();
#define SET(name, n)           \
	lua_pushinteger(L, n); \
	lua_setfield(L, tbl, name)
	SET("ACCEPT", msg_id->tcp_accept);
	SET("CONNECT", msg_id->socket_connect);
	SET("LISTEN", msg_id->socket_listen);
	SET("TCPDATA", msg_id->tcp_data);
	SET("UDPDATA", msg_id->udp_data);
	SET("CLOSE", msg_id->socket_close);
#undef SET
}

SILLY_MOD_API int luaopen_core_net_c(lua_State *L)
{
	luaL_Reg tbl[] = {
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
		{ "readenable",    lreadenable   },
		{ "ntop",          lntop         },
		{ "close",         lclose        },
		{ NULL,            NULL          },
	};
	luaL_checkversion(L);
	luaL_newlibtable(L, tbl);
	silly_error_table(L);
	luaL_setfuncs(L, tbl, 1);
	set_message_type(L, lua_absindex(L, -1));
	return 1;
}