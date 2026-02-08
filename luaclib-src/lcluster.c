#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <lua.h>
#include <lauxlib.h>

#include "silly.h"

#define ACK_BIT (1UL << 31)
#define DEFAULT_QUEUE_SIZE 2048
#define DEFAULT_HARDLIMIT (128u * 1024 * 1024)
#define HASH_SIZE 2048
#define HASH(a) (a % HASH_SIZE)

typedef uint32_t cmd_t;
typedef uint32_t session_t;

#define HEADER_SIZE 4

struct request_header {
	session_t session;
	cmd_t cmd;
	silly_traceid_t traceid;
};
static_assert(sizeof(struct request_header) == 16,
	"request_header layout mismatch");

struct response_header {
	session_t session;
};
static_assert(sizeof(struct response_header) == 4,
	"response_header layout mismatch");
struct packet {
	silly_socket_id_t fd;
	int size;
	char *buff;
};
struct incomplete {
	silly_socket_id_t fd;
	uint8_t hdr_off;
	union {
		uint32_t psize;
		uint8_t bytes[HEADER_SIZE];
	} header;
	uint32_t rsize;
	uint8_t *buff;
	struct incomplete **prev;
	struct incomplete *next;
};

struct netpacket {
	int cap; //default DEFAULT_QUEUE_SIZE
	int head;
	int tail;
	uint32_t hardlimit;
	uint32_t softlimit;
	struct packet *queue;
	struct incomplete *hash[HASH_SIZE];
};

static session_t session_idx = 0;

enum error {
	ERR_HARDLIMIT = -1,
	ERR_PSIZE     = -2,
};

static const char *error_str(int err)
{
	const char *msg;
	switch (err) {
	case ERR_HARDLIMIT:
		msg = "packet size exceeds hardlimit";
		break;
	case ERR_PSIZE:
		msg = "packet size too small";
		break;
	default:
		msg = "unknown error";
		break;
	}
	return msg;
}

static int lcreate(lua_State *L)
{
	struct netpacket *r;
	lua_Integer hardval = luaL_optinteger(L, 1, DEFAULT_HARDLIMIT);
	lua_Integer softval = luaL_optinteger(L, 2, USHRT_MAX);
	if (hardval < 0 || hardval > UINT32_MAX) {
		luaL_error(L, "hardlimit out of range: %d", (int)hardval);
	}
	if (softval < 0 || softval > UINT32_MAX) {
		luaL_error(L, "softlimit out of range: %d", (int)softval);
	}
	if (hardval < softval) {
		luaL_error(L, "hardlimit %d must >= softlimit %d",
			   (int)hardval, (int)softval);
	}
	r = lua_newuserdatauv(L, sizeof(struct netpacket), 0);
	memset(r, 0, sizeof(*r));
	r->cap = DEFAULT_QUEUE_SIZE;
	r->hardlimit = (uint32_t)hardval;
	r->softlimit = (uint32_t)softval;
	r->queue = silly_malloc(r->cap * sizeof(r->queue[0]));
	luaL_getmetatable(L, "silly.net.cluster.c");
	lua_setmetatable(L, -2);
	return 1;
}

static inline struct netpacket *get_netpacket(lua_State *L)
{
	return luaL_checkudata(L, 1, "silly.net.cluster.c");
}

static struct incomplete *get_incomplete(struct netpacket *p,
					 silly_socket_id_t fd)
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

static void expand_queue(struct netpacket *np)
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
	return;
}

static void push_complete(struct netpacket *p, struct incomplete *ic)
{
	struct packet *pk;
	int h = p->head;
	p->head = (p->head + 1) % p->cap;

	pk = &p->queue[h];
	pk->fd = ic->fd;
	assert(ic->header.psize == ic->rsize);
	pk->size = ic->rsize;
	pk->buff = (char *)ic->buff;
	pk->buff[pk->size] = '\0';

	assert(p->head < p->cap);
	assert(p->tail < p->cap);
	if (p->head == p->tail) {
		silly_log_warn("packet queue full\n");
		expand_queue(p);
	}
	return;
}

static inline int validate_psize(struct netpacket *p, uint32_t psize)
{
	if (unlikely(psize < sizeof(struct response_header))) {
		silly_log_error("[cluster] packet size %u too small\n", psize);
		return ERR_PSIZE;
	}
	if (unlikely(psize > p->hardlimit)) {
		silly_log_error("[cluster] packet size %u exceeds hardlimit %u\n",
				psize, p->hardlimit);
		return ERR_HARDLIMIT;
	}
	return 0;
}

static inline int validate_payload(struct incomplete *ic)
{
	struct response_header resp_hdr;
	memcpy(&resp_hdr, ic->buff, sizeof(resp_hdr));
	if ((resp_hdr.session & ACK_BIT) == ACK_BIT)
		return 0;
	if (unlikely(ic->header.psize < sizeof(struct request_header))) {
		silly_log_error("[cluster] request size %u too small from fd %llu\n",
			ic->header.psize, (uint64_t)ic->fd);
		return ERR_PSIZE;
	}
	assert(ic->header.psize == ic->rsize);
	return 0;
}

static int push_once(struct netpacket *p, silly_socket_id_t fd, int size,
		     const uint8_t *buff)
{
	int eat;
	struct incomplete tmp;
	struct incomplete *ic = get_incomplete(p, fd);
	if (ic == NULL) {
		ic = &tmp;
		memset(ic, 0, sizeof(*ic));
		ic->fd = fd;
	}
	//fill header bytes
	eat = 0;
	if (ic->hdr_off < HEADER_SIZE) {
		uint32_t need = HEADER_SIZE - ic->hdr_off;
		uint32_t left = size;
		uint32_t copy = need < left ? need : left;
		memcpy(&ic->header.bytes[ic->hdr_off], buff, copy);
		ic->hdr_off += copy;
		eat += copy;
	}
	if (ic->hdr_off >= HEADER_SIZE) {
		uint32_t need, left, copy;
		assert(ic->hdr_off == HEADER_SIZE);
		if (ic->buff == NULL) {
			int err = validate_psize(p, ic->header.psize);
			if (err < 0) {
				if (ic != &tmp)
					silly_free(ic);
				return err;
			}
			//header complete, alloc body buffer (+1 for '\0')
			ic->buff = silly_malloc(ic->header.psize + 1);
			ic->rsize = 0;
		}
		//fill body
		need = ic->header.psize - ic->rsize;
		left = size - eat;
		copy = need < left ? need : left;
		memcpy(&ic->buff[ic->rsize], &buff[eat], copy);
		ic->rsize += copy;
		eat += copy;
		if (ic->rsize >= ic->header.psize) {
			int err = validate_payload(ic);
			if (err < 0) {
				eat = err;
				silly_free(ic->buff);
			} else {
				push_complete(p, ic);
			}
			if (ic != &tmp)
				silly_free(ic);
			return eat;
		}
	}
	if (ic == &tmp) {
		ic = silly_malloc(sizeof(*ic));
		*ic = tmp;
	}
	put_incomplete(p, ic);
	return eat;
}

static int push(lua_State *L, silly_socket_id_t sid, uint8_t *data,
		int data_size)
{
	int n;
	int left;
	uint8_t *d;
	struct netpacket *p = get_netpacket(L);
	left = data_size;
	d = data;
	do {
		n = push_once(p, sid, left, d);
		if (unlikely(n < 0))
			return n;
		left -= n;
		d += n;
	} while (left);

	return 0;
}

static void clear_incomplete(lua_State *L, silly_socket_id_t sid)
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
	p = luaL_checkudata(L, 1, "silly.net.cluster.c");
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

static void *extstr_free(void *ud, void *ptr, size_t osize, size_t nsize)
{
	(void)ptr;
	(void)osize;
	(void)nsize;
	silly_free(ud);
	return NULL;
}

static int lpop(lua_State *L)
{
	char *buf;
	int size;
	session_t session;
	struct response_header rsp_hdr;
	struct packet *pk = pop_packet(L);
	if (pk == NULL)
		return 0;
	buf = pk->buff;
	pk->buff = NULL;
	memcpy(&rsp_hdr, buf, sizeof(rsp_hdr));
	session = rsp_hdr.session;
	if ((session & ACK_BIT) == ACK_BIT) { //rpc ack
		size = pk->size - sizeof(struct response_header);
		lua_pushinteger(L, pk->fd);
		if (size == 0) {
			silly_free(buf);
			lua_pushliteral(L, "");
		} else {
			lua_pushexternalstring(L,
				buf + sizeof(struct response_header), size,
				extstr_free, buf);
		}
		lua_pushinteger(L, (lua_Integer)(session & ~ACK_BIT));
		lua_pushnil(L);        //cmd
		lua_pushinteger(L, 0); //traceid
	} else {
		struct request_header req_hdr;
		memcpy(&req_hdr, buf, sizeof(req_hdr));
		size = pk->size - sizeof(struct request_header);
		lua_pushinteger(L, pk->fd);
		if (size == 0) {
			silly_free(buf);
			lua_pushliteral(L, "");
		} else {
			lua_pushexternalstring(L,
				buf + sizeof(struct request_header), size,
				extstr_free, buf);
		}
		lua_pushinteger(L, req_hdr.session);
		lua_pushinteger(L, req_hdr.cmd);
		lua_pushinteger(L, (lua_Integer)req_hdr.traceid);
	}
	return 5;
}

static inline int validate_pack_size(struct netpacket *np, cmd_t cmd,
				     uint64_t size)
{
	if (unlikely(size > np->hardlimit)) {
		silly_log_error("[cluster] %d size %u exceeds hardlimit %u\n",
				cmd, size, np->hardlimit);
		return ERR_HARDLIMIT;
	}
	if (unlikely(size > np->softlimit)) {
		silly_log_warn("[cluster] %d size %u exceeds softlimit %u\n",
			       cmd, size, np->softlimit);
	}
	return 0;
}

static int lrequest(lua_State *L)
{
	cmd_t cmd;
	uint8_t *p;
	const char *str;
	size_t size;
	uint64_t body;
	uint32_t total;
	session_t session;
	silly_traceid_t traceid;
	struct request_header req_hdr;
	struct netpacket *np = get_netpacket(L);
	cmd = luaL_checkinteger(L, 2);
	traceid = luaL_checkinteger(L, 3);
	str = getbuffer(L, 4, &size);
	session = session_idx++;
	if (session >= ACK_BIT) {
		session_idx = 0;
		session = 0;
	}
	body = sizeof(struct request_header) + size;
	int err = validate_pack_size(np, cmd, body);
	if (unlikely(err < 0)) {
		lua_pushboolean(L, 0);
		lua_pushstring(L, error_str(err));
		return 2;
	}
	total = HEADER_SIZE + body;
	p = silly_malloc(total + 1);
	memcpy(p, &body, HEADER_SIZE);
	req_hdr.session = session;
	req_hdr.cmd = cmd;
	req_hdr.traceid = traceid;
	memcpy(p + HEADER_SIZE, &req_hdr, sizeof(req_hdr));
	memcpy(p + HEADER_SIZE + sizeof(struct request_header), str, size);
	p[total] = '\0';
	lua_pushinteger(L, session);
	lua_pushexternalstring(L, (char *)p, total, extstr_free, p);
	return 2;
}

static int lresponse(lua_State *L)
{
	uint8_t *p;
	const char *str;
	size_t size;
	uint64_t body;
	uint32_t total;
	session_t session;
	struct response_header rsp_hdr;
	struct netpacket *np = get_netpacket(L);
	session = luaL_checkinteger(L, 2) | ACK_BIT;
	str = getbuffer(L, 3, &size);
	body = sizeof(struct response_header) + size;
	int err = validate_pack_size(np, 0, body);
	if (unlikely(err < 0)) {
		lua_pushboolean(L, 0);
		lua_pushstring(L, error_str(err));
		return 2;
	}
	total = HEADER_SIZE + body;
	p = silly_malloc(total + 1);
	memcpy(p, &body, HEADER_SIZE);
	rsp_hdr.session = session;
	memcpy(p + HEADER_SIZE, &rsp_hdr, sizeof(rsp_hdr));
	memcpy(p + HEADER_SIZE + sizeof(struct response_header), str, size);
	p[total] = '\0';
	lua_pushexternalstring(L, (char *)p, total, extstr_free, p);
	return 1;
}

static int lclear(lua_State *L)
{
	silly_socket_id_t sid = luaL_checkinteger(L, 2);
	clear_incomplete(L, sid);
	return 0;
}

//@input
//	netpacket
//	type
//	fd
static int lpush(lua_State *L)
{
	silly_socket_id_t fd = luaL_checkinteger(L, 2);
	uint8_t *ptr = lua_touserdata(L, 3);
	int size = luaL_checkinteger(L, 4);
	int err = push(L, fd, ptr, size);
	silly_free(ptr);
	if (unlikely(err < 0)) {
		lua_pushboolean(L, 0);
		lua_pushstring(L, error_str(err));
		return 2;
	}
	lua_pushboolean(L, 1);
	return 1;
}

static int packet_gc(lua_State *L)
{
	int i;
	struct netpacket *pk = get_netpacket(L);
	for (i = 0; i < HASH_SIZE; i++) {
		struct incomplete *ic, *t;
		ic = pk->hash[i];
		while (ic) {
			t = ic;
			ic = ic->next;
			silly_free(t->buff);
			silly_free(t);
		}
	}
	i = pk->tail;
	while (i != pk->head) {
		if (pk->queue[i].buff != NULL) {
			silly_free(pk->queue[i].buff);
		}
		i = (i + 1) % pk->cap;
	}
	silly_free(pk->queue);
	pk->queue = NULL;
	return 0;
}

SILLY_MOD_API int luaopen_silly_net_cluster_c(lua_State *L)
{
	luaL_Reg tbl[] = {
		{ "create",   lcreate   },
		{ "pop",      lpop      },
		{ "push",     lpush     },
		{ "request",  lrequest  },
		{ "response", lresponse },
		{ "clear",    lclear    },
		{ NULL,       NULL      },
	};
	luaL_checkversion(L);
	luaL_newmetatable(L, "silly.net.cluster.c");
	lua_pushliteral(L, "__gc");
	lua_pushcfunction(L, packet_gc);
	lua_settable(L, -3);
	luaL_newlibtable(L, tbl);
	luaL_setfuncs(L, tbl, 0);
	return 1;
}
