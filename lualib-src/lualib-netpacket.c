#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <lua.h>
#include <lauxlib.h>

#include "silly.h"
#include "silly_log.h"
#include "silly_trace.h"
#include "silly_malloc.h"

#define ACK_BIT (1UL << 31)
#define DEFAULT_QUEUE_SIZE 2048
#define HASH_SIZE 2048
#define HASH(a) (a % HASH_SIZE)

#ifndef min
#define min(a, b) ((a) > (b) ? (b) : (a))
#endif

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
	struct incomplete **prev;
	struct incomplete *next;
};

struct netpacket {
	int cap; //default DEFAULT_QUEUE_SIZE
	int head;
	int tail;
	struct packet *queue;
	struct incomplete *hash[HASH_SIZE];
};

static session_t session_idx = 0;
static int lcreate(lua_State *L)
{
	struct netpacket *r = lua_newuserdatauv(L, sizeof(struct netpacket), 0);
	memset(r, 0, sizeof(*r));
	r->cap = DEFAULT_QUEUE_SIZE;
	r->queue = silly_malloc(r->cap * sizeof(r->queue[0]));
	luaL_getmetatable(L, "netpacket");
	lua_setmetatable(L, -2);
	return 1;
}

static inline struct netpacket *get_netpacket(lua_State *L)
{
	return luaL_checkudata(L, 1, "netpacket");
}

static struct incomplete *get_incomplete(struct netpacket *p, int fd)
{
	int idx = HASH(fd);
	struct incomplete *i;
	i = p->hash[idx];
	while (i) {
		if (i->fd == fd) {
			*i->prev = i->next;
			if (i->next != NULL)
				i->next->prev = i->prev;
			return i;
		}
		i = i->next;
	}
	return NULL;
}

static void put_incomplete(struct netpacket *p, struct incomplete *ic)
{
	int idx = HASH(ic->fd);
	struct incomplete *i;
	i = p->hash[idx];
	ic->next = i;
	ic->prev = &p->hash[idx];
	p->hash[HASH(ic->fd)] = ic;
	if (i != NULL)
		i->prev = &ic->next;
	return;
}

static void expand_queue(lua_State *L, struct netpacket *np)
{
	int i, h, count;
	struct packet *queue, *newqueue;
	queue = np->queue;
	h = np->tail;
	count = np->cap;
	np->cap += DEFAULT_QUEUE_SIZE;
	np->queue = newqueue = silly_malloc(np->cap * sizeof(np->queue[0]));
	np->tail = 0;
	np->head = count;
	for (i = 0; i < count; i++) {
		newqueue[i] = queue[h % count];
		++h;
	}
	silly_free(queue);
	luaL_getmetatable(L, "netpacket");
	lua_setmetatable(L, -2);
	return;
}

static void push_complete(lua_State *L, struct netpacket *p,
			  struct incomplete *ic)
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
		silly_log_warn("packet queue full\n");
		expand_queue(L, p);
	}
	return;
}

static int push_once(lua_State *L, int fd, int size, const uint8_t *buff)
{
	int eat;
	struct netpacket *p = get_netpacket(L);
	struct incomplete *ic = get_incomplete(p, fd);
	if (ic) {                     //continue it
		if (ic->rsize >= 0) { //have already alloc memory
			assert(ic->buff);
			eat = min(ic->psize - ic->rsize, size);
			memcpy(&ic->buff[ic->rsize], buff, eat);
			ic->rsize += eat;
		} else { //have no enough psize info
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
			eat += 1; //for the length header
		}
	} else { //new incomplete
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

static void push(lua_State *L, int sid, uint8_t *data, int data_size)
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

	return;
}

static void clear_incomplete(lua_State *L, int sid)
{
	struct netpacket *p = get_netpacket(L);
	struct incomplete *ic = get_incomplete(p, sid);
	if (ic == NULL)
		return;
	silly_free(ic->buff);
	silly_free(ic);
	return;
}

static inline const char *getbuffer(lua_State *L, int stk, size_t *sz)
{
	if (lua_type(L, stk) == LUA_TSTRING) {
		return lua_tolstring(L, stk, sz);
	} else {
		*sz = luaL_checkinteger(L, stk + 1);
		return lua_touserdata(L, stk);
	}
	return NULL;
}

static inline struct packet *pop_packet(lua_State *L)
{
	struct netpacket *p;
	p = luaL_checkudata(L, 1, "netpacket");
	assert(p->head < p->cap);
	assert(p->tail < p->cap);
	if (p->tail == p->head) { //empty
		return NULL;
	} else {
		int t = p->tail;
		p->tail = (p->tail + 1) % p->cap;
		return &p->queue[t];
	}
}

//rpc_cookie {traceid(uint64),cmd(uint32),session(uint32)}

#define req_cookie_size \
	(sizeof(silly_traceid_t) + sizeof(cmd_t) + sizeof(session_t))
#define req_traceid_ref(ptr) (*(silly_traceid_t *)(ptr))
#define req_cmd_ref(ptr) (*(cmd_t *)(ptr + sizeof(silly_traceid_t)))
#define req_session_ref(ptr) \
	(*(session_t *)(ptr + sizeof(silly_traceid_t) + sizeof(cmd_t)))

#define ack_cookie_size (sizeof(session_t))
#define ack_session_ref(ptr) (*(session_t *)(ptr))

static int lpop(lua_State *L)
{
	int size;
	char *buf;
	session_t session;
	struct packet *pk = pop_packet(L);
	if (pk == NULL)
		return 0;
	size = pk->size - ack_cookie_size;
	buf = pk->buff;
	if (size < 0)
		return 0;
	//WARN: pointer cast may not align, can't cross platform
	session = ack_session_ref(buf + size);
	if ((session & ACK_BIT) == ACK_BIT) { //rpc ack
		lua_pushinteger(L, pk->fd);
		lua_pushlightuserdata(L, buf);
		lua_pushinteger(L, size);
		lua_pushinteger(L, (lua_Integer)(session & ~ACK_BIT));
		lua_pushnil(L);        //cmd
		lua_pushinteger(L, 0); //traceid
	} else {
		void *cookie;
		size = pk->size - req_cookie_size;
		cookie = (void *)(buf + size);
		lua_pushinteger(L, pk->fd);
		lua_pushlightuserdata(L, buf);
		lua_pushinteger(L, size);
		lua_pushinteger(L, session);
		lua_pushinteger(L, req_cmd_ref(cookie));
		lua_pushinteger(L, (lua_Integer)req_traceid_ref(cookie));
	}
	return 6;
}

static int lrequest(lua_State *L)
{
	cmd_t cmd;
	uint8_t *p;
	const char *str;
	void *cookie;
	size_t size, body;
	session_t session;
	silly_traceid_t traceid;
	cmd = luaL_checkinteger(L, 1);
	traceid = luaL_checkinteger(L, 2);
	str = getbuffer(L, 3, &size);
	if (size > (USHRT_MAX - req_cookie_size)) {
		luaL_error(L, "netpacket.pack data large then:%d\n",
			   USHRT_MAX - req_cookie_size);
	}
	session = session_idx++;
	if (session >= ACK_BIT) {
		session_idx = 0;
		session = 0;
	}
	body = size + req_cookie_size;
	p = silly_malloc(2 + body);
	p[0] = (body >> 8) & 0xff;
	p[1] = body & 0xff;
	memcpy(p + 2, str, size);
	//WARN: pointer cast may not align, can't cross platform
	cookie = (void *)&p[2 + size];
	req_cmd_ref(cookie) = cmd;
	req_session_ref(cookie) = session;
	req_traceid_ref(cookie) = traceid;
	lua_pushinteger(L, session);
	lua_pushlightuserdata(L, p);
	lua_pushinteger(L, 2 + body);
	return 3;
}

static int lresponse(lua_State *L)
{
	uint8_t *p;
	const char *str;
	void *cookie;
	size_t size, body;
	session_t session;
	session = luaL_checkinteger(L, 1) | ACK_BIT;
	str = getbuffer(L, 2, &size);
	if (size > (USHRT_MAX - ack_cookie_size)) {
		luaL_error(L, "netpacket.pack data large then:%d\n",
			   USHRT_MAX - ack_cookie_size);
	}
	body = size + ack_cookie_size;
	p = silly_malloc(2 + body);
	p[0] = (body >> 8) & 0xff;
	p[1] = body & 0xff;
	memcpy(p + 2, str, size);
	//WARN: pointer cast may not align, can't cross platform
	cookie = (void *)&p[2 + size];
	ack_session_ref(cookie) = session;
	lua_pushlightuserdata(L, p);
	lua_pushinteger(L, 2 + body);
	return 2;
}

static int lclear(lua_State *L)
{
	int sid = luaL_checkinteger(L, 2);
	assert(sid >= 0);
	clear_incomplete(L, sid);

	return 0;
}

static int ltostring(lua_State *L)
{
	char *buff;
	int size;
	buff = lua_touserdata(L, 1);
	size = luaL_checkinteger(L, 2);
	lua_pushlstring(L, buff, size);
	silly_free(buff);
	return 1;
}

static int ldrop(lua_State *L)
{
	int type = lua_type(L, 1);
	if (type != LUA_TLIGHTUSERDATA)
		return luaL_error(L,
				  "netpacket.drop can only drop lightuserdata");
	void *p = lua_touserdata(L, 1);
	silly_free(p);
	return 0;
}

//@input
//	netpacket
//	type
//	fd
static int lmessage(lua_State *L)
{
	struct silly_message_socket *sm = tosocket(lua_touserdata(L, 2));
	lua_settop(L, 1);
	switch (sm->type) {
	case SILLY_SDATA:
		push(L, sm->sid, sm->data, sm->ud);
		return 0;
	case SILLY_SCLOSE:
		clear_incomplete(L, sm->sid);
		return 0;
	case SILLY_SACCEPT:
	case SILLY_SCONNECTED:
		return 0;
	default:
		silly_log_error("lmessage unspport:%d\n", sm->type);
		assert(!"never come here");
		return 0;
	}
}

static int packet_gc(lua_State *L)
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
	silly_free(pk->queue);
	pk->queue = NULL;
	return 0;
}

int luaopen_core_netpacket(lua_State *L)
{
	luaL_Reg tbl[] = {
		{ "create",   lcreate   },
		{ "pop",      lpop      },
		{ "request",  lrequest  },
		{ "response", lresponse },
		{ "clear",    lclear    },
		{ "drop",     ldrop     },
		{ "tostring", ltostring },
		{ "message",  lmessage  },
		{ NULL,       NULL      },
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
