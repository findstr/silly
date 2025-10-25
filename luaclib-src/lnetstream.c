#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <lua.h>
#include <lauxlib.h>

#include "silly.h"
#include "luastr.h"

#ifndef max
#define max(a, b) ((a) > (b) ? (a) : (b))
#endif

#ifndef min
#define min(a, b) ((a) < (b) ? (a) : (b))
#endif

#define SB (1)
#define METANAME "silly.netstream"

#define NB_INIT_EXP (6)

struct delim_pos {
	int i;
	int size;
};

struct node {
	int size;
	int offset;
	char *buff;
};

struct node_buffer {
	int bytes;
	int cap;
	int readi;
	int writei;
	char delim;
	int delim_last_checki;
	struct node nodes[1];
};

struct socket_buffer {
	silly_socket_id_t fd;
	int limit;
	int pause;
	struct node_buffer *nb;
};

#define node_bytes(n) ((n)->size - (n)->offset)
#define node_buff(n) ((n)->buff + (n)->offset)

#define nb_head(nb) (&(nb)->nodes[nb->readi])

#define needpause(sb) ((nb_bytes(sb->nb)) >= (sb->limit))

// borrowed from luaO_ceillog2
static int ceillog2(unsigned int x)
{
	static const uint8_t log_2[256] = {
		/* log_2[i] = ceil(log2(i - 1)) */
		0, 1, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 4, 4, 4, 4, 5, 5, 5, 5,
		5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 6, 6, 6, 6, 6, 6, 6, 6,
		6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6,
		6, 6, 6, 6, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
		7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
		7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
		7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 8, 8, 8, 8, 8, 8, 8, 8,
		8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
		8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
		8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
		8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
		8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
		8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8
	};
	int l = 0;
	x--;
	while (x >= 256) {
		l += 8;
		x >>= 8;
	}
	return l + log_2[x];
}

static struct node_buffer *nb_expand(struct node_buffer *nb)
{
	int size = 0;
	int bytes = 0;
	int last_checki = 0;
	char delim = 0;
	int cap_exp = NB_INIT_EXP;
	if (nb != NULL) {
		int size_exp = 0;
		delim = nb->delim;
		bytes = nb->bytes;
		size = nb->writei - nb->readi;
		last_checki = nb->delim_last_checki - nb->readi;
		assert(size >= 0);
		assert(last_checki >= 0);
		//round up to the nearest power of 2
		size_exp = ceillog2(size + 1);
		cap_exp = max(size_exp, cap_exp);
		if (nb->readi > 0) {
			memmove(&nb->nodes[0], &nb->nodes[nb->readi],
				size * sizeof(struct node));
		}
	}
	int cap = 1 << cap_exp;
	int need = sizeof(struct node_buffer) + sizeof(struct node) * (cap - 1);
	nb = (struct node_buffer *)silly_realloc(nb, need);
	nb->cap = cap;
	nb->readi = 0;
	nb->writei = size;
	nb->bytes = bytes;
	nb->delim = delim;
	nb->delim_last_checki = last_checki;
	return nb;
}

static inline void nb_free(struct node_buffer *sb)
{
	for (int i = sb->readi; i < sb->writei; i++) {
		struct node *n = &sb->nodes[i];
		silly_free(n->buff);
		n->buff = NULL;
		n->size = 0;
		n->offset = 0;
	}
	silly_free(sb);
}

static inline struct node *nb_append(struct node_buffer **sbp)
{
	struct node_buffer *sb = *sbp;
	if (sb->writei >= sb->cap) {
		sb = nb_expand(sb);
		*sbp = sb;
	}
	return &sb->nodes[sb->writei++];
}

static inline void nb_addsize(struct node_buffer *sb, int sz)
{
	sb->bytes += sz;
}

static inline struct node *nb_peek(struct node_buffer *sb)
{
	assert(sb->readi < sb->writei);
	return &sb->nodes[sb->readi];
}

static inline void nb_reset_delim(struct node_buffer *nb, char delim)
{
	nb->delim = delim;
	nb->delim_last_checki = nb->readi;
}

static inline void nb_pop(struct node_buffer *nb)
{
	assert(nb->readi < nb->writei);
	struct node *n = &nb->nodes[nb->readi];
	nb->bytes -= n->size;
	nb->readi++;
	if (nb->readi > nb->delim_last_checki) {
		nb_reset_delim(nb, 0);
	}
	silly_free(n->buff);
	n->buff = NULL;
	n->size = 0;
	n->offset = 0;
}

static inline void node_consume(struct node_buffer *nb, struct node *n,
				int size)
{
	n->offset += size;
	if (n->offset >= n->size)
		nb_pop(nb);
}

static inline int nb_bytes(struct node_buffer *nb)
{
	if (nb->readi >= nb->writei) {
		assert(nb->bytes == 0);
		return 0;
	}
	return nb->bytes - nb->nodes[nb->readi].offset;
}

static void nb_pushsize(struct node_buffer *nb, lua_State *L, int sz)
{
	if (sz == 0) {
		lua_pushliteral(L, "");
		return;
	}
	assert(sz >= 0);
	struct node *n = nb_peek(nb);
	if (node_bytes(n) >= sz) {
		char *s = node_buff(n);
		lua_pushlstring(L, s, sz);
		node_consume(nb, n, sz);
	} else {
		struct luaL_Buffer b;
		luaL_buffinitsize(L, &b, sz);
		while (sz > 0) {
			int tmp;
			n = nb_peek(nb);
			tmp = min(sz, node_bytes(n));
			luaL_addlstring(&b, node_buff(n), tmp);
			node_consume(nb, n, tmp);
			sz -= tmp;
		}
		assert(sz == 0);
		luaL_pushresult(&b);
	}
}

static void nb_pushuntil(lua_State *L, struct node_buffer *nb, const struct delim_pos *pos)
{
	struct node *n;
	if (pos->i == nb->readi) { // only push one data
		n = nb_head(nb);
		assert(pos->size <= node_bytes(n));
		lua_pushlstring(L, node_buff(n), pos->size);
		node_consume(nb, n, pos->size);
	} else {
		struct luaL_Buffer b;
		luaL_buffinit(L, &b);
		for (int i = nb->readi; i < pos->i; i++) {
			struct node *n = &nb->nodes[i];
			luaL_addlstring(&b, node_buff(n), node_bytes(n));
			nb_pop(nb);
		}
		n = nb_head(nb);
		assert(pos->i == nb->readi);
		assert(pos->size <= node_bytes(n));
		luaL_addlstring(&b, node_buff(n), pos->size);
		node_consume(nb, n, pos->size);
		luaL_pushresult(&b);
	}
}

static int nb_finddelim(struct node_buffer *nb, int delim, struct delim_pos *pos)
{
	if (delim != nb->delim) {
		nb_reset_delim(nb, delim);
	}
	assert(nb->delim_last_checki >= nb->readi);
	assert(nb->delim_last_checki <= nb->writei);
	for (int ni = nb->delim_last_checki; ni < nb->writei; ni++) {
		struct node *n = &nb->nodes[ni];
		int nbytes = node_bytes(n);
		const char *s = node_buff(n);
		const char *e = s + nbytes;
		const char *x = memchr(s, delim, e - s);
		if (x != NULL) {
			pos->i = ni;
			pos->size = (int)(x - s) + 1;
			return 0;
		}
		nb->delim_last_checki = ni;
	}
	return -1;
}

static int lfree(lua_State *L)
{
	struct socket_buffer *sb;
	if (lua_isnil(L, SB))
		return 0;
	sb = (struct socket_buffer *)luaL_checkudata(L, SB, METANAME);
	if (sb->nb != NULL) {
		nb_free(sb->nb);
		sb->nb = NULL;
	}
	return 0;
}

static int lnew(lua_State *L)
{
	struct socket_buffer *sb;
	sb = (struct socket_buffer *)lua_newuserdatauv(L, sizeof(*sb), 0);
	sb->fd = luaL_checkinteger(L, 1);
	sb->limit = INT_MAX;
	sb->pause = 0;
	sb->nb = NULL;
	sb->nb = nb_expand(NULL);
	if (luaL_newmetatable(L, METANAME)) {
		lua_pushcfunction(L, lfree);
		lua_setfield(L, -2, "__gc");
	}
	lua_setmetatable(L, -2);
	return 1;
}

static inline void read_enable(struct socket_buffer *sb)
{
	if (sb->pause == 0)
		return;
	sb->pause = 0;
	silly_socket_readenable(sb->fd, 1);
}

static inline void read_pause(struct socket_buffer *sb)
{
	if (sb->pause == 1)
		return;
	sb->pause = 1;
	silly_socket_readenable(sb->fd, 0);
}

static inline void read_adjust(struct socket_buffer *sb)
{
	if (needpause(sb))
		read_pause(sb);
	else
		read_enable(sb);
}

//@input
//	node, silly_message_socket
//@return
//	socket buffer

static int push(lua_State *L, char *data, int sz)
{
	struct node *new;
	struct socket_buffer *sb;
	sb = (struct socket_buffer *)luaL_checkudata(L, SB, METANAME);
	new = nb_append(&sb->nb);
	new->size = sz;
	new->buff = data;
	new->offset = 0;
	nb_addsize(sb->nb, sz);
	if (!sb->pause && needpause(sb))
		read_pause(sb);
	return nb_bytes(sb->nb);
}

//@input
//	socket buffer
//	read byte count
//@return
//	string or nil
static int lread(lua_State *L)
{
	lua_Integer readn;
	struct socket_buffer *sb;
	if (lua_isnil(L, SB)) {
		lua_pushnil(L);
		return 1;
	}
	sb = (struct socket_buffer *)luaL_checkudata(L, SB, METANAME);
	assert(sb);
	readn = luaL_checkinteger(L, SB + 1);
	if (readn <= 0) {
		lua_pushliteral(L, "");
	} else if (readn > nb_bytes(sb->nb)) {
		if (sb->pause)
			read_enable(sb);
		lua_pushnil(L);
	} else {
		nb_pushsize(sb->nb, L, readn);
		read_adjust(sb);
	}
	return 1;
}

//@input
//	socket buffer
//	read delim
//@return
//	string or nil
static int lreadline(lua_State *L)
{
	struct luastr delim;
	struct delim_pos pos;
	struct socket_buffer *sb;
	if (lua_isnil(L, SB)) {
		lua_pushnil(L);
		return 1;
	}
	sb = (struct socket_buffer *)luaL_checkudata(L, SB, METANAME);
	luastr_check(L, SB + 1, &delim);
	luaL_argcheck(L, delim.len == 1, SB + 1, "delim length must be 1");
	if (nb_finddelim(sb->nb, delim.str[0], &pos) < 0) {
		read_enable(sb);
		lua_pushnil(L);
		return 1;
	}
	nb_pushuntil(L, sb->nb, &pos);
	read_adjust(sb);
	return 1;
}

//@input
//	socket buffer
//@return
//	buff size
static int lsize(lua_State *L)
{
	struct socket_buffer *sb;
	if (lua_isnil(L, SB)) {
		lua_pushinteger(L, 0);
	} else {
		sb = (struct socket_buffer *)luaL_checkudata(L, SB, METANAME);
		if (sb != NULL) {
			lua_pushinteger(L, nb_bytes(sb->nb));
		} else {
			lua_pushinteger(L, 0);
		}
	}
	return 1;
}

//@input
// socket buffer
//@return
//	previously limit
static int llimit(lua_State *L)
{
	int prev, limit;
	struct socket_buffer *sb;
	sb = (struct socket_buffer *)luaL_checkudata(L, SB, METANAME);
	limit = luaL_checkinteger(L, SB + 1);
	prev = sb->limit;
	sb->limit = limit;
	read_adjust(sb);
	lua_pushinteger(L, prev);
	return 1;
}

static int lpush(lua_State *L)
{
	char *str = lua_touserdata(L, SB + 1);
	int size = luaL_checkinteger(L, SB + 2);
	int total_size = push(L, str, size);
	lua_pushinteger(L, total_size);
	return 1;
}

static int ltodata(lua_State *L)
{
	uint8_t *data = lua_touserdata(L, 1);
	size_t datasz = luaL_checkinteger(L, 2);
	lua_pushlstring(L, (char *)data, datasz);
	silly_free(data);
	return 1;
}

static int tpush(lua_State *L)
{
	size_t sz;
	const char *src = luaL_checklstring(L, 2, &sz);
	void *dat = silly_malloc(sz);
	memcpy(dat, src, sz);
	push(L, dat, sz);
	return 0;
}

static int tcap(lua_State *L)
{
	struct socket_buffer *sb;
	sb = (struct socket_buffer *)luaL_checkudata(L, SB, METANAME);
	lua_pushinteger(L, sb->nb->cap);
	return 1;
}

SILLY_MOD_API int luaopen_silly_netstream(lua_State *L)
{
	luaL_Reg tbl[] = {
		{ "new",      lnew      },
                { "free",     lfree     },
		{ "push",     lpush     },
                { "read",     lread     },
		{ "size",     lsize     },
                { "limit",    llimit    },
		{ "readline", lreadline },
                { "tpush",    tpush     },
		{ "tcap",     tcap      },
		{ "todata",   ltodata   },
                { NULL,       NULL      },
	};
	luaL_newlib(L, tbl);
	return 1;
}