#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <arpa/inet.h>
#include <lua.h>
#include <lauxlib.h>

#include "silly.h"
#include "silly_log.h"
#include "silly_malloc.h"

#define DEFAULT_QUEUE_SIZE 2048
#define HASH_SIZE 2048
#define HASH(a) (a % HASH_SIZE)

#define min(a, b)		((a) > (b) ? (b) : (a))

typedef uint32_t cmd_t;
typedef uint32_t session_t;

struct packet {
	int fd;
	int size;
	char *buff;
};

struct incomplete {
	int fd;
	int rsize;
	int psize;
	uint8_t *buff;
	struct incomplete *prev;
	struct incomplete *next;
};

struct netpacket {
	int cap;			//default DEFAULT_QUEUE_SIZE
	int head;
	int tail;
	struct incomplete *hash[HASH_SIZE];
	struct packet queue[DEFAULT_QUEUE_SIZE];	//for more effective gc
};

static int
lcreate(lua_State *L)
{
	struct netpacket *r = lua_newuserdata(L, sizeof(struct netpacket));
	memset(r, 0, sizeof(*r));
	r->cap = DEFAULT_QUEUE_SIZE;
	luaL_getmetatable(L, "netpacket");
	lua_setmetatable(L, -2);
	return 1;
}

static inline struct netpacket *
get_netpacket(lua_State *L)
{
	return luaL_checkudata(L, 1, "netpacket");
}

static struct incomplete *
get_incomplete(struct netpacket *p, int fd)
{
	struct incomplete *i;
	i = p->hash[HASH(fd)];
	while (i) {
		if (i->fd == fd) {
			if (i->prev == NULL)
				p->hash[HASH(fd)] = i->next;
			else
				i->prev->next = i->next;
			return i;
		}
		i = i->next;
	}
	return NULL;
}

static void
put_incomplete(struct netpacket *p, struct incomplete *ic)
{
	struct incomplete *i;
	i = p->hash[HASH(ic->fd)];
	ic->next = i;
	ic->prev = NULL;
	p->hash[HASH(ic->fd)] = ic;
}

static void
expand_queue(lua_State *L, struct netpacket *p)
{
	int i, h;
	struct netpacket *new = lua_newuserdata(L, sizeof(struct netpacket) + sizeof(struct packet) * p->cap);
	new->cap = p->cap + DEFAULT_QUEUE_SIZE;
	new->head = p->cap;
	new->tail = 0;
	memcpy(new->hash, p->hash, sizeof(new->hash));
	memset(p->hash, 0, sizeof(p->hash));
	h = p->tail;
	for (i = 0; i < p->cap; i++) {
		new->queue[i] = p->queue[h % p->cap];
		++h;
	}
	luaL_getmetatable(L, "netpacket");
	lua_setmetatable(L, -2);
	p->head = p->tail = 0;
	lua_replace(L, 1);
	return ;
}

static void
push_complete(lua_State *L, struct netpacket *p, struct incomplete *ic)
{
	struct packet *pk;
	int h = p->head;
	p->head = (p->head + 1) % p->cap;

	pk = &p->queue[h];
	pk->fd = ic->fd;
	assert(ic->psize == ic->rsize);
	pk->size = ic->psize;
	pk->buff = (char *)ic->buff;

	assert(p->head < p->cap);
	assert(p->tail < p->cap);
	if (p->head == p->tail) {
		silly_log("packet queue full\n");
		expand_queue(L, p);
	}

	return ;
}

static int
push_once(lua_State *L, int fd, int size, const uint8_t *buff)
{
	int eat;
	struct netpacket *p = get_netpacket(L);
	struct incomplete *ic = get_incomplete(p, fd);
	if (ic) {	//continue it
		if (ic->rsize >= 0) {	//have already alloc memory
			assert(ic->buff);
			eat = min(ic->psize - ic->rsize, size);
			memcpy(&ic->buff[ic->rsize], buff, eat);
			ic->rsize += eat;
		} else {		//have no enough psize info
			assert(ic->rsize == -1);
			ic->psize |= *buff;
			ic->buff = (uint8_t *)silly_malloc(ic->psize);

			++buff;
			--size;
			++ic->rsize;

			assert(ic->rsize == 0);

			eat = min(ic->psize - ic->rsize, size);
			memcpy(&ic->buff[ic->rsize], buff, eat);
			ic->rsize += eat;
			eat += 1;		//for the length header
		}
	} else {	//new incomplete
		ic = silly_malloc(sizeof(*ic));
		ic->fd = fd;
		ic->buff = NULL;
		ic->psize = 0;
		ic->rsize = -2;
		if (size >= 2) {
			ic->psize = (*buff << 8) | *(buff + 1);
			ic->rsize = min(ic->psize, size - 2);
			ic->buff = silly_malloc(ic->psize);
			eat = ic->rsize + 2;
			memcpy(ic->buff, buff + 2, ic->rsize);
		} else {
			assert(size == 1);
			ic->psize |= *buff << 8;
			ic->rsize = -1;
			eat = 1;
		}
	}

	if (ic->rsize == ic->psize) {
		push_complete(L, p, ic);
		silly_free(ic);
	} else {
		assert(ic->rsize < ic->psize);
		put_incomplete(p, ic);
	}
	return eat;
}

static void
push(lua_State *L, int sid, uint8_t *data, int data_size)
{
	int n;
	int left;
	uint8_t *d;
	left = data_size;
	d = data;
	do {
		n = push_once(L, sid, left, d);
		left -= n;
		d += n;
	} while (left);

	return ;
}

static void
clear_incomplete(lua_State *L, int sid)
{
	struct netpacket *p = get_netpacket(L);
	struct incomplete *ic = get_incomplete(p, sid);
	if (ic == NULL)
		return ;
	silly_free(ic->buff);
	silly_free(ic);
	return ;
}

static inline const char *
getbuffer(lua_State *L, int *stk, size_t *sz)
{
	int n = *stk;
	if (lua_type(L, n) == LUA_TSTRING) {
		*stk = n + 1;
		return lua_tolstring(L, n, sz);
	} else {
		*stk = n + 2;
		*sz = luaL_checkinteger(L, n + 1);
		return lua_touserdata(L, n);
	}
	return NULL;
}

static inline struct packet *
pop_packet(lua_State *L)
{
	struct netpacket *p;
	p = luaL_checkudata(L, 1, "netpacket");
	assert(p->head < p->cap);
	assert(p->tail < p->cap);
	if (p->tail == p->head) {	//empty
		return NULL;
	} else {
		int t = p->tail;
		p->tail = (p->tail + 1) % p->cap;
		return &p->queue[t];
	}
}

static int
lpop(lua_State *L)
{
	struct packet *pk = pop_packet(L);
	if (pk == NULL)
		return 0;
	lua_pushinteger(L, pk->fd);
	lua_pushlightuserdata(L, pk->buff);
	lua_pushinteger(L, pk->size);
	return 3;
}

static int
lpack(lua_State *L)
{
	uint8_t *p;
	int stk = 1;
	size_t size;
	const char *str;
	str = getbuffer(L, &stk, &size);
	if (size > USHRT_MAX)
		luaL_error(L, "netpacket.pack data large then:%d\n", USHRT_MAX);
	p = silly_malloc(2 + size);
	p[0] = (size >> 8) & 0xff;
	p[1] = size & 0xff;
	memcpy(p + 2, str, size);
	lua_pushlightuserdata(L, p);
	lua_pushinteger(L, 2 + size);
	return 2;
}

static int
lmsgpop(lua_State *L)
{
	int size;
	char *buf;
	cmd_t cmd;
	struct packet *pk = pop_packet(L);
	if (pk == NULL)
		return 0;
	size = pk->size - sizeof(cmd_t);
	buf = pk->buff;
	if (size < 0)
		return 0;
	//WARN: pointer cast may not align, can't cross platform
	cmd = *(cmd_t *)(buf + size);
	lua_pushinteger(L, pk->fd);
	lua_pushlightuserdata(L, buf);
	lua_pushinteger(L, size);
	lua_pushinteger(L, cmd);
	return 4;
}

static int
lmsgpack(lua_State *L)
{
	uint8_t *p;
	const char *str;
	size_t size, body;
	int cmd, stk = 1;
	str = getbuffer(L, &stk, &size);
	if (size > (USHRT_MAX - sizeof(cmd_t))) {
		luaL_error(L, "netpacket.pack data large then:%d\n",
			USHRT_MAX - sizeof(cmd_t));
	}
	cmd = luaL_checkinteger(L, stk);
	body = size + sizeof(cmd_t);
	p = silly_malloc(2 + body);
	p[0] = (body >> 8) & 0xff;
	p[1] = body & 0xff;
	memcpy(p + 2, str, size);
	//WARN: pointer cast may not align, can't cross platform
	*(cmd_t *)&p[size+2] = cmd;
	lua_pushlightuserdata(L, p);
	lua_pushinteger(L, 2 + body);
	return 2;
}

struct rpc_cookie {
	cmd_t cmd;
	session_t session;
};

static int
lrpcpop(lua_State *L)
{
	int size;
	char *buf;
	struct rpc_cookie *rpc;
	struct packet *pk = pop_packet(L);
	if (pk == NULL)
		return 0;
	size = pk->size - sizeof(struct rpc_cookie);
	buf = pk->buff;
	if (size < 0)
		return 0;
	//WARN: pointer cast may not align, can't cross platform
	rpc = (struct rpc_cookie *)(buf + size);
	lua_pushinteger(L, pk->fd);
	lua_pushlightuserdata(L, buf);
	lua_pushinteger(L, size);
	lua_pushinteger(L, rpc->cmd);
	lua_pushinteger(L, rpc->session);
	return 5;
}

static int
lrpcpack(lua_State *L)
{
	cmd_t cmd;
	uint8_t *p;
	const char *str;
	size_t size, body;
	struct rpc_cookie *rpc;
	int session, stk = 1;
	str = getbuffer(L, &stk, &size);
	if (size > (USHRT_MAX - sizeof(struct rpc_cookie))) {
		luaL_error(L, "netpacket.pack data large then:%d\n",
			USHRT_MAX - sizeof(struct rpc_cookie));
	}
	cmd = luaL_checkinteger(L, stk);
	session = luaL_checkinteger(L, stk+1);
	body = size + sizeof(struct rpc_cookie);
	p = silly_malloc(2 + body);
	p[0] = (body >> 8) & 0xff;
	p[1] = body & 0xff;
	memcpy(p + 2, str, size);
	//WARN: pointer cast may not align, can't cross platform
	rpc = (struct rpc_cookie *)&p[2 + size];
	rpc->cmd = cmd;
	rpc->session = session;
	lua_pushlightuserdata(L, p);
	lua_pushinteger(L, 2 + body);
	return 2;
}

static int
lclear(lua_State *L)
{
	int sid = luaL_checkinteger(L, 2);
	assert(sid >= 0);
	clear_incomplete(L, sid);

	return 0;
}

static int
ltostring(lua_State *L)
{
	char *buff;
	int size;
	buff = lua_touserdata(L, 1);
	size = luaL_checkinteger(L, 2);
	lua_pushlstring(L, buff, size);
	silly_free(buff);
	return 1;
}

static int
ldrop(lua_State *L)
{
	int type = lua_type(L, 1);
	if (type != LUA_TLIGHTUSERDATA)
		return luaL_error(L, "netpacket.drop can only drop lightuserdata");
	void *p = lua_touserdata(L, 1);
	silly_free(p);
	return 0;
}

//@input
//	netpacket
//	type
//	fd
static int
lmessage(lua_State *L)
{
	struct silly_message_socket *sm= tosocket(lua_touserdata(L, 2));
	lua_settop(L, 1);
	switch (sm->type) {
	case SILLY_SDATA:
		push(L, sm->sid, sm->data, sm->ud);
		return 1;
	case SILLY_SCLOSE:
		clear_incomplete(L, sm->sid);
		return 1;
	case SILLY_SACCEPT:
	case SILLY_SCONNECTED:
		return 1;
	default:
		silly_log("lmessage unspport:%d\n", sm->type);
		assert(!"never come here");
		return 1;
	}
}

static int
packet_gc(lua_State *L)
{
	int i;
	struct netpacket *pk = get_netpacket(L);
	for (i = 0; i < HASH_SIZE; i++) {
		struct incomplete *ic = pk->hash[i];
		while (ic) {
			struct incomplete *t = ic;
			ic = ic->next;
			silly_free(t->buff);
			silly_free(t);
		}
	}
	return 0;
}

int luaopen_sys_netpacket(lua_State *L)
{
	luaL_Reg tbl[] = {
		{"create", lcreate},
		{"pop", lpop},
		{"pack", lpack},
		{"msgpop", lmsgpop},
		{"msgpack", lmsgpack},
		{"rpcpop", lrpcpop},
		{"rpcpack", lrpcpack},
		{"clear", lclear},
		{"tostring", ltostring},
		{"drop", ldrop},
		{"message", lmessage},
		{NULL, NULL},
	};
	luaL_checkversion(L);
	luaL_newmetatable(L, "netpacket");
	lua_pushliteral(L, "__gc");
	lua_pushcfunction(L, packet_gc);
	lua_settable(L, -3);
	luaL_newlibtable(L, tbl);
	luaL_setfuncs(L, tbl, 0);
	return 1;
}
