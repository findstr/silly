#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <lua.h>
#include <lauxlib.h>

#include "silly.h"
#include "silly_log.h"
#include "silly_socket.h"
#include "silly_malloc.h"

#ifndef min
#define min(a, b) ((a) < (b) ? (a) : (b))
#endif

#define POOL (lua_upvalueindex(1))
#define NB (1)

//2^4=16KiB
#define CHUNK (1 << 4)
//2^11=2KiB
#define CHUNK_EXP (11 - 4)

struct node {
	int size;
	char *buff;
	struct node *next;
};

struct node_buffer {
	int sid;
	int size;
	int offset;
	int limit;
	int pause;
	struct node *head;
	struct node **tail;
};

#define needpause(nb) ((nb->size) >= (nb->limit))

static int free_pool(lua_State *L)
{
	struct node *n, *end;
	n = (struct node *)luaL_checkudata(L, 1, "nodepool");
	int sz = lua_rawlen(L, 1);
	assert(sz % sizeof(struct node) == 0);
	sz /= sizeof(struct node);
	end = n + sz;
	while (n < end) {
		if (n->buff) {
			silly_free(n->buff);
			n->buff = NULL;
		}
		++n;
	}
	return 0;
}

static struct node *new_pool(lua_State *L, int n)
{
	int i;
	struct node *free;
	free = (struct node *)lua_newuserdatauv(L, sizeof(struct node) * n, 0);
	memset(free, 0, sizeof(struct node) * n);
	for (i = 0; i < n - 1; i++)
		free[i].next = &free[i + 1];
	free[i].next = NULL;
	if (luaL_newmetatable(L, "nodepool")) {
		lua_pushcfunction(L, free_pool);
		lua_setfield(L, -2, "__gc");
	}
	lua_setmetatable(L, -2);
	return free;
}

static struct node *new_node(lua_State *L)
{
	lua_rawgeti(L, POOL, 1);
	struct node *free;
	if (lua_isnil(L, -1)) {
		int sz, exp;
		struct node *new;
		int n = lua_rawlen(L, POOL);
		if (n == 0)
			n = 1;
		exp = n > CHUNK_EXP ? CHUNK_EXP : n;
		sz = CHUNK << exp;
		new = new_pool(L, sz);
		lua_rawseti(L, POOL, n + 1);
		free = new;
	} else {
		free = (struct node *)lua_touserdata(L, -1);
	}
	lua_pop(L, 1);
	if (free->next)
		lua_pushlightuserdata(L, free->next);
	else
		lua_pushnil(L);
	lua_rawseti(L, POOL, 1);
	return free;
}

static inline void append_node(struct node_buffer *nb, struct node *n)
{
	n->next = NULL;
	*nb->tail = n;
	nb->tail = &n->next;
	nb->size += n->size;
	return;
}

//'remove_node'may be called by 'lfree' which may be called in
//'nodebuffer'.__gc, and 'nodebuffer'.__gc may called before
//'nodepool'.__gc, so 'nodebuffer'.__gc should set the n->buff as 'null'
//after it free n->buff. In lua GC circle, one circle call __gc function
//and next circle really clear the memory of object,
//so even 'nodebuffer'.__gc free the n->buff, the pointer 'n' is sitll valid

static void remove_node(lua_State *L, struct node_buffer *nb, struct node *n)
{
	assert(n == nb->head);
	assert(nb->tail);
	nb->head = nb->head->next;
	nb->offset = 0;
	if (nb->head == NULL)
		nb->tail = &nb->head;
	silly_free(n->buff);
	n->buff = NULL;
	lua_rawgeti(L, POOL, 1);
	struct node *free = lua_touserdata(L, -1);
	if (free == NULL) {
		n->next = NULL;
		lua_pushlightuserdata(L, n);
		lua_rawseti(L, POOL, 1);
	} else {
		n->next = free->next;
		free->next = n;
	}
	lua_pop(L, 1);
	return;
}

static int lfree(lua_State *L)
{
	struct node_buffer *nb;
	if (lua_isnil(L, NB))
		return 0;
	nb = (struct node_buffer *)luaL_checkudata(L, NB, "nodebuffer");
	nb->size = 0;
	while (nb->head)
		remove_node(L, nb, nb->head);
	return 0;
}

static int lnew(lua_State *L)
{
	struct node_buffer *nb;
	nb = (struct node_buffer *)lua_newuserdatauv(L, sizeof(*nb), 0);
	nb->sid = luaL_checkinteger(L, 1);
	nb->offset = 0;
	nb->size = 0;
	nb->head = NULL;
	nb->limit = INT_MAX;
	nb->pause = 0;
	nb->tail = &nb->head;
	if (luaL_newmetatable(L, "nodebuffer")) {
		lua_pushvalue(L, POOL);
		lua_pushcclosure(L, lfree, 1);
		lua_setfield(L, -2, "__gc");
	}
	lua_setmetatable(L, -2);
	return 1;
}

static inline void read_enable(struct node_buffer *nb)
{
	if (nb->pause == 0)
		return;
	nb->pause = 0;
	silly_socket_readctrl(nb->sid, SOCKET_READ_ENABLE);
}

static inline void read_pause(struct node_buffer *nb)
{
	if (nb->pause == 1)
		return;
	nb->pause = 1;
	silly_socket_readctrl(nb->sid, SOCKET_READ_PAUSE);
}

static inline void read_adjust(struct node_buffer *nb)
{
	if (needpause(nb))
		read_pause(nb);
	else
		read_enable(nb);
}

//@input
//	node, silly_message_socket
//@return
//	node buffer

static int push(lua_State *L, int sid, char *data, int sz)
{
	struct node_buffer *nb;
	struct node *new = new_node(L);
	new->size = sz;
	new->buff = data;
	nb = (struct node_buffer *)luaL_checkudata(L, NB, "nodebuffer");
	assert(nb->sid == sid);
	append_node(nb, new);
	if (!nb->pause && needpause(nb))
		read_pause(nb);
	return nb->size;
}

static int pushstring(lua_State *L, struct node_buffer *nb, int sz)
{
	assert(sz >= 0);
	struct node *n = nb->head;
	if (n->size >= sz) {
		char *s = &n->buff[nb->offset];
		lua_pushlstring(L, s, sz);
		nb->offset += sz;
		n->size -= sz;
		if (n->size == 0)
			remove_node(L, nb, n);
	} else {
		char *buff = (char *)silly_malloc(sz);
		char *p = buff;
		while (sz) {
			int tmp;
			tmp = min(sz, n->size);
			memcpy(p, &n->buff[nb->offset], tmp);
			p += tmp;
			sz -= tmp;
			nb->offset += tmp;
			n->size -= tmp;
			if (n->size == 0) {
				remove_node(L, nb, n);
				n = nb->head;
			}
		}
		assert(sz == 0);
		lua_pushlstring(L, buff, p - buff);
		silly_free(buff);
	}
	lua_replace(L, 1);
	lua_settop(L, 1);
	return 1;
}

static int compare(struct node *n, int start, int sz, const char *delim,
		   int delim_len)
{
	while (delim_len > 0) {
		if (sz >= delim_len) {
			return memcmp(&n->buff[start], delim, delim_len);
		} else if (memcmp(&n->buff[start], delim, sz) != 0) {
			return -1;
		} else if (n->next == NULL) {
			return -1;
		} else {
			assert(delim_len > sz);
			delim_len -= sz;
			delim += sz;
			n = n->next;
			sz = n->size;
			start = 0;
		}
	}

	return -1;
}

static int checkdelim(struct node_buffer *nb, const char *delim, int delim_len)
{
	int ret = -1;
	int nr = 0;
	struct node *n;
	int start = nb->offset;
	for (n = nb->head; n; n = n->next) {
		int i;
		int sz = n->size;
		for (i = 0; i < n->size; i++) {
			int e = compare(n, start, sz, delim, delim_len);
			if (e == 0) //return value from memcmp
				break;
			nr += 1;
			sz -= 1;
			start += 1;
			continue;
		}
		if (i >= n->size) {
			start = 0;
			continue;
		}
		nr += delim_len;
		ret = nr;
		break;
	}
	return ret;
}

static int lreadall(lua_State *L)
{
	int readsize, sz;
	struct node_buffer *nb;
	if (lua_isnil(L, 1)) {
		lua_pushliteral(L, "");
		return 1;
	}
	nb = (struct node_buffer *)luaL_checkudata(L, NB, "nodebuffer");
	readsize = luaL_optinteger(L, NB + 1, INT_MAX);
	sz = nb->size;
	if (sz == 0) {
		lua_pushliteral(L, "");
	} else if (readsize >= sz) {
		nb->size = 0;
		pushstring(L, nb, sz);
	} else {
		nb->size = sz - readsize;
		pushstring(L, nb, readsize);
	}
	read_adjust(nb);
	return 1;
}

//@input
//	node buffer
//	read byte count
//@return
//	string or nil
static int lread(lua_State *L)
{
	struct node_buffer *nb;
	if (lua_isnil(L, NB)) {
		lua_pushnil(L);
		return 1;
	}
	nb = (struct node_buffer *)luaL_checkudata(L, NB, "nodebuffer");
	assert(nb);
	lua_Integer readn = luaL_checkinteger(L, NB + 1);
	if (readn <= 0) {
		lua_pushliteral(L, "");
		return 1;
	} else if (readn > nb->size) {
		if (nb->pause)
			read_enable(nb);
		lua_pushnil(L);
		return 1;
	}
	nb->size -= readn;
	read_adjust(nb);
	return pushstring(L, nb, readn);
}

//@input
//	pool
//	node buffer
//	read delim
//@return
//	string or nil
static int lreadline(lua_State *L)
{
	int readn;
	const char *delim;
	size_t delim_len;
	struct node_buffer *nb;
	if (lua_isnil(L, NB)) {
		lua_pushnil(L);
		return 1;
	}
	nb = luaL_checkudata(L, NB, "nodebuffer");
	delim = lua_tolstring(L, NB + 1, &delim_len);
	readn = checkdelim(nb, delim, delim_len);
	if (readn == -1 || readn > nb->size) {
		if (nb->pause)
			read_enable(nb);
		lua_pushnil(L);
		return 1;
	}
	nb->size -= readn;
	read_adjust(nb);
	return pushstring(L, nb, readn);
}

//@input
//	node buffer
//@return
//	buff size
static int lsize(lua_State *L)
{
	struct node_buffer *nb;
	if (lua_isnil(L, NB)) {
		lua_pushinteger(L, 0);
	} else {
		nb = luaL_checkudata(L, NB, "nodebuffer");
		lua_pushinteger(L, nb->size);
	}
	return 1;
}

//@input
// node buffer
//@return
//	previously limit
static int llimit(lua_State *L)
{
	int prev, limit;
	struct node_buffer *nb;
	if (lua_isnil(L, NB)) {
		return -1;
	}
	nb = luaL_checkudata(L, NB, "nodebuffer");
	limit = luaL_checkinteger(L, NB + 1);
	prev = nb->limit;
	nb->limit = limit;
	read_adjust(nb);
	lua_pushinteger(L, prev);
	return 1;
}

static int lpush(lua_State *L)
{
	int size;
	char *str;
	struct silly_message_socket *msg = tosocket(lua_touserdata(L, NB + 1));
	switch (msg->type) {
	case SILLY_SDATA:
		str = (char *)msg->data;
		//prevent silly_work free the msg->data
		//it will be exist until it be read out
		msg->data = NULL;
		size = push(L, msg->sid, str, msg->ud);
		break;
	case SILLY_SACCEPT:
	case SILLY_SCLOSE:
	case SILLY_SCONNECTED:
	default:
		size = 0;
		silly_log_error("lmessage unspport:%d\n", msg->type);
		assert(!"never come here");
		break;
	}
	lua_pushinteger(L, size);
	return 1;
}

static int ltodata(lua_State *L)
{
	uint8_t *data;
	size_t datasz;
	struct silly_message *sm = (struct silly_message *)lua_touserdata(L, 1);
	switch (sm->type) {
	case SILLY_SUDP:
	case SILLY_SDATA:
		data = tosocket(sm)->data;
		datasz = tosocket(sm)->ud;
		break;
	default:
		luaL_error(L, "tomsgstring unsupport message type");
		return 0;
	}
	lua_pushlstring(L, (char *)data, datasz);
	return 1;
}

static int tpush(lua_State *L)
{
	size_t sz;
	int fd = luaL_checkinteger(L, 2);
	const char *src = luaL_checklstring(L, 3, &sz);
	void *dat = silly_malloc(sz);
	memcpy(dat, src, sz);
	push(L, fd, dat, sz);
	return 0;
}

int luaopen_core_netstream(lua_State *L)
{
	luaL_Reg tbl[] = {
		{ "new",      lnew      },
		{ "free",     lfree     },
		{ "push",     lpush     },
		{ "read",     lread     },
		{ "size",     lsize     },
		{ "limit",    llimit    },
		{ "readline", lreadline },
		{ "readall",  lreadall  },
		{ "todata",   ltodata   },
		{ "tpush",    tpush     },
		{ NULL,       NULL      },
	};

	luaL_checkversion(L);
	luaL_newlibtable(L, tbl);
	lua_newtable(L);
	luaL_setfuncs(L, tbl, 1);
	return 1;
}
