#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <lua.h>
#include <lauxlib.h>

#include "silly.h"
#include "silly_malloc.h"

#define min(a, b) ((a) < (b) ? (a) : (b))

#define POOL (lua_upvalueindex(1))
#define NB (1)

#define POOL_CHUNK (32)
#define POOL_CHUNK_LIMIT (512)

struct node {
	struct node *next;
	int start;
	int size;
	char *buff;
};

struct node_buffer {
	int sid;
	int size;
	struct node *head;
	struct node **tail;
};

static int
free_pool(struct lua_State *L)
{
	int i;
	struct node *n = (struct node *)luaL_checkudata(L, 1, "nodepool");
	int sz = lua_rawlen(L, 1);
	assert(sz % sizeof(struct node) == 0);
	sz /= sizeof(struct node);

	for (i = 0; i < sz; i++) {
		if (n[i].buff)
			silly_free(n[i].buff);
	}

	return 0;
}

static struct node *
new_pool(struct lua_State *L, int n)
{
	int i;
	struct node *free = (struct node *)lua_newuserdata(L, sizeof(struct node) * n);
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

static struct node *
new_node(struct lua_State *L)
{
	lua_rawgeti(L, POOL, 1);
	struct node *free;
	if (lua_isnil(L, -1)) {
		int sz;
		int n = lua_rawlen(L, POOL);
		if (n == 0)
			n = 1;
		sz = POOL_CHUNK << n;
		if (sz > POOL_CHUNK_LIMIT)
			sz = POOL_CHUNK_LIMIT;
		struct node *new = new_pool(L, sz);
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


static inline void
append_node(struct node_buffer *nb, struct node *n)
{
	n->next = NULL;
	*nb->tail = n;
	nb->tail = &n->next;
	nb->size += n->size;
	return ;
}

static void
remove_node(lua_State *L, struct node_buffer *nb, struct node *n)
{
	assert(n == nb->head);
	assert(nb->tail);
	nb->head = nb->head->next;
	if (nb->head == NULL)
		nb->tail = &nb->head;
	assert(n->buff);
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
	return ;
}

//@input
//	node buffer

static int
lclear(struct lua_State *L)
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


//@input
//	node, silly_message_socket
//@return
//	node buffer

static int
push(struct lua_State *L, int sid, char *data, int sz)
{
	struct node_buffer *nb;
	struct node *new = new_node(L);
	new->start = 0;
	new->size = sz;
	new->buff = data;
	if (lua_isnil(L, NB)) {
		nb = (struct node_buffer *)lua_newuserdata(L, sizeof(struct node_buffer));
		nb->sid = sid;
		nb->size = 0;
		nb->head = NULL;
		nb->tail = &nb->head;
		if (luaL_newmetatable(L, "nodebuffer")) {
			lua_pushvalue(L, POOL);
			lua_pushcclosure(L, lclear, 1);
			lua_setfield(L, -2, "__gc");
		}
		lua_setmetatable(L, -2);
		lua_replace(L, 1);
	} else {
		nb = (struct node_buffer *)luaL_checkudata(L, NB, "nodebuffer");
		assert(nb->sid == sid);
	}
	append_node(nb, new);
	lua_settop(L, 1);
	return 1;
}

static int
pushstring(struct lua_State *L, struct node_buffer *nb, int sz)
{
	assert(sz > 0);
	struct node *n = nb->head;
	if (n->size >= sz) {
		char *s = &n->buff[n->start];
		lua_pushlstring(L, s, sz);
		n->start += sz;
		n->size -= sz;
		if (n->size == 0)
			remove_node(L, nb, n);
	} else {
		char *buff = (char *)silly_malloc(sz);
		char *p = buff;
		while (sz) {
			int tmp;
			tmp = min(sz, n->size);

			memcpy(p, &n->buff[n->start], tmp);
			p += tmp;
			sz -= tmp;
			n->start += tmp;
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

static int
compare(struct node *n, int start, int sz, const char *delim, int delim_len)
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

static int
checkdelim(struct node_buffer *nb, const char *delim, int delim_len)
{
	int ret = -1;
	int nr = 0;
	struct node *n;

	for (n = nb->head; n; n = n->next) {
		int i;
		int start = n->start;
		int sz = n->size;
		for (i = 0; i < n->size; i++) {
			int e = compare(n, start, sz, delim, delim_len);
			if (e == 0)	//return value from memcmp
				break;
			nr += 1;
			sz -= 1;
			start += 1;
			continue;
		}
		if (i >= n->size)
			continue;
		nr += delim_len;
		ret = nr;
		break;
	}

	return ret;
}

static int
lcheck(struct lua_State *L)
{
	if (lua_isnil(L, 1)) {
		lua_pushinteger(L, 0);
		return 1;
	}
	struct node_buffer *nb = (struct node_buffer *)luaL_checkudata(L, 1, "nodebuffer");
	assert(nb);
	lua_pushinteger(L, nb->size);
	return 1;
}

//@input
//	node buffer
//	read byte count
//@return
//	string or nil
static int
lread(struct lua_State *L)
{
	struct node_buffer *nb;
	if (lua_isnil(L, NB)) {
		lua_pushnil(L);
		return 1;
	}
	nb = (struct node_buffer *)luaL_checkudata(L, NB, "nodebuffer");
	assert(nb);
	int readn = luaL_checkinteger(L, NB + 1);
	if (readn > nb->size) {
		lua_pushnil(L);
		return 1;
	}

	nb->size -= readn;
	return pushstring(L, nb, readn);
}

//@input
//	pool
//	node buffer
//	read delim
//@return
//	string or nil
static int
lreadline(struct lua_State *L)
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
		lua_pushnil(L);
		return 1;
	}
	nb->size -= readn;
	return pushstring(L, nb, readn);
}

static int
lpush(lua_State *L)
{
	char *str;
	struct silly_message_socket *msg = tosocket(lua_touserdata(L, NB + 1));
	switch (msg->type) {
	case SILLY_SDATA:
		str = (char *)msg->data;
		//prevent silly_work free the msg->data
		//it will be exist until it be read out
		msg->data = NULL;
		return push(L, msg->sid, str, msg->ud);
	case SILLY_SACCEPT:
	case SILLY_SCLOSE:
	case SILLY_SCONNECTED:
	default:
		assert(!"never come here");
		fprintf(stderr, "lmessage unspport:%d\n", msg->type);
		return 1;
	}
}

static int
ltodata(lua_State *L)
{
	uint8_t *data;
	size_t datasz;
	struct silly_message *sm = (struct silly_message *)lua_touserdata(L, 1);
	switch (sm->type) {
	case SILLY_SDATA:
		data = sdata(sm)->data;
		datasz = sdata(sm)->ud;
		break;
	case SILLY_SUDP:
		data = sudp(sm)->data;
		datasz = sudp(sm)->ud;
		break;
	default:
		luaL_error(L, "tomsgstring unsupport message type");
		return 0;
	}
	lua_pushlstring(L, (char *)data, datasz);
	return 1;
}

static int
tpush(lua_State *L)
{
	size_t sz;
	int fd = luaL_checkinteger(L, 2);
	const char *src = luaL_checklstring(L, 3, &sz);
	void *dat = silly_malloc(sz);
	memcpy(dat, src, sz);
	return push(L, fd, dat, sz);
}

int luaopen_netstream(lua_State *L)
{
	luaL_Reg tbl[] = {
		{"push", lpush},
		{"tpush", tpush},
		{"clear", lclear},
		{"read", lread},
		{"readline", lreadline},
		{"check", lcheck},
		{"todata", ltodata},
		{NULL, NULL},
	};

	luaL_checkversion(L);
	luaL_newlibtable(L, tbl);
	lua_newtable(L);
	luaL_setfuncs(L, tbl, 1);
	return 1;
}

