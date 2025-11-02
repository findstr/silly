#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <lua.h>
#include <lauxlib.h>

#include "silly.h"
#include "luastr.h"
#include "idpool.h"

#ifndef max
#define max(a, b) ((a) > (b) ? (a) : (b))
#endif

#ifndef min
#define min(a, b) ((a) < (b) ? (a) : (b))
#endif

#define BUFFER (1)
#define METANAME "silly.adt.buffer"

#define NB_INIT_EXP (6)

struct delim_pos {
	int i;
	int size;
};

struct node {
	int ref;
	int bytes;
	const char *buff;
};

struct buffer {
	void *meta;
	int bytes;
	int cap;
	int readi;
	int writei;
	char delim;
	int delim_last_checki;
	int offset;
	struct node *nodes;
	struct id_pool idx;
};

struct reader {
	lua_State *L;
	struct buffer *b;
	int ref_tbl;
};


// borrowed from luaO_ceillog2
static int ceillog2(unsigned int x)
{
	static const uint8_t log_2[256] = {  /* log_2[i] = ceil(log2(i - 1)) */
		0,1,2,2,3,3,3,3,4,4,4,4,4,4,4,4,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,
		6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,
		7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,
		7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,
		8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,
		8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,
		8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,
		8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8
	};
	int l = 0;
	x--;
	while (x >= 256) {
		l += 8;
		x >>= 8;
	}
	return l + log_2[x];
}

static void node_destroy(lua_State *L, struct buffer *b, int ref_tbl, struct node *n)
{
	if (n->ref > 0) {
		lua_pushnil(L);
		lua_seti(L, ref_tbl, n->ref);
		id_pool_free(&b->idx, n->ref);
		n->ref = 0;
	} else {
		silly_free((void *)n->buff);
	}
	n->buff = NULL;
	n->bytes = 0;
}

static void buffer_expand(struct buffer *b)
{
	int cap_exp = NB_INIT_EXP;
	//round up to the nearest power of 2
	int size = b->writei - b->readi;
	int size_exp = ceillog2(size + 1);
	cap_exp = max(size_exp, cap_exp);
	if (b->readi > 0) {
		memmove(&b->nodes[0], &b->nodes[b->readi],
			size * sizeof(struct node));
	}
	int last_checki = b->delim_last_checki - b->readi;
	int cap = 1 << cap_exp;
	int need = sizeof(struct node) * cap;
	b->cap = cap;
	b->readi = 0;
	b->writei = size;
	b->delim_last_checki = last_checki;
	b->nodes = (struct node *)silly_realloc(b->nodes, need);
}


static inline struct node *buffer_append(struct buffer *b)
{
	if (b->writei >= b->cap) {
		buffer_expand(b);
		assert(b->writei < b->cap);
	}
	return &b->nodes[b->writei++];
}

static inline struct node *buffer_head(struct buffer *b)
{
	assert(b->readi < b->writei);
	return &b->nodes[b->readi];
}

static inline void buffer_reset_delim(struct buffer *b, char delim)
{
	b->delim = delim;
	b->delim_last_checki = b->readi;
}

static inline void reader_pop(struct reader *r)
{
	struct buffer *b = r->b;
	assert(b->readi < b->writei);
	struct node *n = &b->nodes[b->readi];
	b->readi++;
	b->offset = 0;
	if (b->readi > b->delim_last_checki) {
		buffer_reset_delim(b, 0);
	}
	node_destroy(r->L, b, r->ref_tbl, n);
}

static inline void reader_consume(struct reader *r, int size)
{
	struct buffer *b = r->b;
	int total = size;
	while (size > 0) {
		struct node *head = buffer_head(b);
		int bytes = head->bytes;
		if (bytes > size) {
			head->bytes -= size;
			r->b->offset += size;
			break;
		}
		size -= bytes;
		reader_pop(r);
	}
	b->bytes -= total;
	assert(b->bytes >= 0);
}

static void reader_push_single_node(struct reader *r, struct node *n, int size)
{
	assert(size <= n->bytes);
	if (r->b->offset == 0 && n->bytes == size && n->ref > 0) {
		lua_geti(r->L, r->ref_tbl, n->ref);
	} else {
		const char *s = n->buff + r->b->offset;
		lua_pushlstring(r->L, s, size);
	}
	reader_consume(r, size);
}

static void reader_push_size(struct reader *r, int sz)
{
	lua_State *L = r->L;
	struct buffer *b = r->b;
	if (sz == 0) {
		lua_pushliteral(L, "");
		return;
	}
	assert(sz >= 0);
	struct node *n = buffer_head(b);
	if (sz <= n->bytes) {
		reader_push_single_node(r, n, sz);
	} else {
		struct luaL_Buffer buf;
		luaL_buffinitsize(L, &buf, sz);
		while (sz > 0) {
			int once;
			n = buffer_head(b);
			once = min(sz, n->bytes);
			luaL_addlstring(&buf, n->buff + b->offset, once);
			reader_consume(r, once);
			sz -= once;
		}
		assert(sz == 0);
		luaL_pushresult(&buf);
	}
}

static void reader_push_delim(struct reader *r, const struct delim_pos *pos)
{
	struct node *n;
	struct buffer *b = r->b;
	lua_State *L = r->L;
	if (pos->i == b->readi) { // only push one data
		n = buffer_head(b);
		reader_push_single_node(r, n, pos->size);
	} else {
		struct luaL_Buffer buf;
		struct node *head;
		int n = pos->i - b->readi;
		luaL_buffinit(L, &buf);
		for (int i = 0; i < n; i++) {
			head = buffer_head(b);
			luaL_addlstring(&buf, head->buff+b->offset, head->bytes);
			reader_consume(r, head->bytes);
		}
		assert(pos->i == b->readi);
		head = buffer_head(b);
		assert(pos->size <= head->bytes);
		luaL_addlstring(&buf, head->buff+b->offset, pos->size);
		reader_consume(r, pos->size);
		luaL_pushresult(&buf);
	}
}

static int buffer_find_delim(struct buffer *b, int delim, struct delim_pos *pos)
{
	int offset;
	if (delim != b->delim) {
		buffer_reset_delim(b, delim);
	}
	assert(b->delim_last_checki >= b->readi);
	assert(b->delim_last_checki <= b->writei);
	offset = b->readi == b->delim_last_checki ? b->offset : 0;
	for (int ni = b->delim_last_checki; ni < b->writei; ni++) {
		struct node *n = &b->nodes[ni];
		const char *s = n->buff + offset;
		const char *e = s + n->bytes;
		const char *x = memchr(s, delim, e - s);
		if (x != NULL) {
			pos->i = ni;
			pos->size = (int)(x - s) + 1;
			return 0;
		}
		b->delim_last_checki = ni;
		offset = 0;
	}
	return -1;
}

static int lnew(lua_State *L)
{
	struct buffer *b;
	b = (struct buffer *)lua_newuserdatauv(L, sizeof(*b), 1);
	luaL_getmetatable(L, METANAME);
	lua_setmetatable(L, -2);
	memset(b, 0, sizeof(*b));
	b->meta = &lnew;
	lua_newtable(L);
	lua_setiuservalue(L, 1, 1);
	id_pool_init(&b->idx);
	return 1;
}

static inline struct buffer *check_buffer(lua_State *L, int index)
{
	struct buffer *b = (struct buffer *)lua_touserdata(L, index);
	if (unlikely(b == NULL || b->meta != (void *)&lnew))
		luaL_typeerror(L, index, METANAME);
	return b;
}

static struct buffer *clear(lua_State *L)
{
	int ref_tbl;
	struct buffer *b = check_buffer(L, BUFFER);
	lua_getiuservalue(L, BUFFER, 1);
	ref_tbl = lua_gettop(L);
	for (int i = b->readi; i < b->writei; i++) {
		struct node *n = &b->nodes[i];
		node_destroy(L, b, ref_tbl, n);
	}
	lua_pop(L, 1);
	b->bytes = 0;
	b->offset = 0;
	b->delim = 0;
	b->delim_last_checki = 0;
	b->readi = 0;
	b->writei = 0;
	return b;
}

static int lgc(lua_State *L)
{
	struct buffer *b;
	if (lua_isnil(L, BUFFER))
		return 0;
	b = clear(L);
	silly_free(b->nodes);
	id_pool_destroy(&b->idx);
	b->meta = NULL;
	return 0;
}

static int push_data(lua_State *L, const char *data, int sz, int ref)
{
	struct node *new;
	struct buffer *b = check_buffer(L, BUFFER);
	new = buffer_append(b);
	new->ref = ref;
	new->bytes = sz;
	new->buff = data;
	b->bytes += sz;
	return b->bytes;
}

static void read_bytes(lua_State *L, struct buffer *b, int bytes)
{
	if (bytes <= 0) {
		lua_pushliteral(L, "");
	} else if (bytes > b->bytes) {
		lua_pushnil(L);
	} else {
		struct reader r;
		lua_getiuservalue(L, BUFFER, 1);
		r.L = L;
		r.b = b;
		r.ref_tbl = lua_gettop(L);
		reader_push_size(&r, bytes);
		lua_replace(L, -2);
	}
}

static void read_line(lua_State *L, struct buffer *b, int delim)
{
	struct reader r;
	struct delim_pos pos;
	if (buffer_find_delim(b, delim, &pos) < 0) {
		lua_pushnil(L);
	} else {
		lua_getiuservalue(L, BUFFER, 1);
		r.L = L;
		r.b = b;
		r.ref_tbl = lua_gettop(L);
		reader_push_delim(&r, &pos);
		lua_replace(L, -2);
	}
}

//@input
//	buffer
//	read byte count/delimiter
//@return
//	string or nil
static int lread(lua_State *L)
{
	int vstk;
	struct luastr delim;
	struct buffer *b = check_buffer(L, BUFFER);
	vstk = BUFFER+1;
	switch (lua_type(L, vstk)) {
	case LUA_TNUMBER:
		read_bytes(L, b, lua_tointeger(L, vstk));
		break;
	case LUA_TSTRING:
		luastr_check(L, BUFFER + 1, &delim);
		luaL_argcheck(L, delim.len == 1, vstk, "delimiter length must be 1");
		read_line(L, b, delim.str[0]);
		break;
	default:
		return luaL_error(L, "invalid read argument type");
	}
	lua_pushinteger(L, b->bytes);
	return 2;
}

static int lclear(lua_State *L)
{
	clear(L);
	return 0;
}

static int lsize(lua_State *L)
{
	struct buffer *b = check_buffer(L, BUFFER);
	lua_pushinteger(L, b->bytes);
	return 1;
}

static int ref_value(lua_State *L, struct buffer *b, int stk)
{
	int ref = id_pool_alloc(&b->idx);
	lua_getiuservalue(L, 1, 1);
	lua_pushvalue(L, stk);
	lua_seti(L, -2, ref);
	lua_pop(L, 1);
	assert(ref > 0);
	return ref;
}

static int lappend(lua_State *L)
{
	int ref;
	size_t len, bytes;
	const char *ptr;
	int vstk, type;
	struct buffer *b = check_buffer(L, BUFFER);
	vstk = BUFFER+1;
	type = lua_type(L, vstk);
	switch (type) {
	case LUA_TSTRING:
		ptr = lua_tolstring(L, vstk, &len);
		ref = ref_value(L, b, vstk);
		bytes = push_data(L, ptr, len, ref);
		break;
	case LUA_TLIGHTUSERDATA:
		ptr = lua_touserdata(L, vstk);
		len = luaL_checkinteger(L, vstk+1);
		bytes = push_data(L, ptr, len, 0);
		break;
	default:
		return luaL_error(L, "invalid append argument type");
	}
	lua_pushinteger(L, bytes);
	return 1;
}

static int ldump(lua_State *L)
{
	struct buffer *b = check_buffer(L, BUFFER);
	lua_createtable(L, 0, 8);

	lua_pushinteger(L, b->bytes);
	lua_setfield(L, -2, "bytes");

	lua_pushinteger(L, b->cap);
	lua_setfield(L, -2, "cap");

	lua_pushinteger(L, b->readi);
	lua_setfield(L, -2, "readi");

	lua_pushinteger(L, b->writei);
	lua_setfield(L, -2, "writei");

	lua_pushinteger(L, b->offset);
	lua_setfield(L, -2, "offset");

	lua_pushinteger(L, b->delim);
	lua_setfield(L, -2, "delim");

	lua_pushinteger(L, b->delim_last_checki);
	lua_setfield(L, -2, "delim_last_checki");

	// Export uservalue table (ref table) for testing
	lua_getiuservalue(L, BUFFER, 1);
	lua_setfield(L, -2, "refs");

	return 1;
}

SILLY_MOD_API int luaopen_silly_adt_buffer(lua_State *L)
{
	luaL_Reg tbl[] = {
		{ "new",    lnew    },
		{ "append", lappend },
		{ "read",   lread   },
		{ "clear",  lclear  },
		{ "size",   lsize   },
		{ "dump",   ldump   },
		{ NULL,     NULL    },
	};
	luaL_newlib(L, tbl);
	luaL_newmetatable(L, METANAME);
	lua_pushvalue(L, -2);
	lua_setfield(L, -2, "__index");
	lua_pushcfunction(L, lgc);
	lua_setfield(L, -2, "__gc");
	lua_pop(L, 1);
	return 1;
}
