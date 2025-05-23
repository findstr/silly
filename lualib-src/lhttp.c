#include <assert.h>
#include <string.h>
#include <stdlib.h>
#include <stdint.h>
#include <lua.h>
#include <lauxlib.h>

#include "http2_table.h"
#include "silly_malloc.h"

#define STATIC_TBL_SIZE (61)
#ifdef SILLY_TEST
#define HTTP2_HEADER_SIZE (4096)
#else
#define HTTP2_HEADER_SIZE (256)
#endif
#define FRAME_HDR_SIZE (9)

struct lstr {
	const char *str;
	size_t len;
};

///////////////////////////hpack///////////////////////////

struct hpack {
	int hard_limit;
	int soft_limit;
	int table_size;
	int queue_head;
	int queue_tail;
	int queue_used_min;
	int evict_count;
};

struct unpack_ctx {
	struct root *huffman;
	int stat;
	int dyna;
	unsigned int flag;
	const unsigned char *p;
	const unsigned char *e;
	struct hpack *hpack;
};

struct pack_ctx {
	int stat;
	int dyna;
	int kstk;
	int vstk;
	struct lstr kstr;
	struct lstr vstr;
	luaL_Buffer b;
	struct hpack *hpack;
};

struct node {
	uint8_t sym;
	int8_t codelen;
	int children[256]; //TODO:optimise children to pointer
};

struct root {
	int size;
	int free;
	struct node node;
	struct node *pool;
};

static struct node *alloc(struct root *huffman)
{
	struct node *n;
	if (huffman->free >= huffman->size) {
		int newsz = (huffman->size + 64);
		huffman->size = newsz;
		huffman->pool = silly_realloc(huffman->pool,
					      newsz * sizeof(huffman->pool[0]));
	}
	n = &huffman->pool[huffman->free++];
	n->codelen = -1;
	memset(n->children, -1, sizeof(n->children));
	return n;
}

static void add_node(struct root *huffman, uint8_t sym, uint32_t code,
		     int codelen)
{
	int i, shift, start, end, id;
	struct node *n;
	struct node *curr = &huffman->node;
	struct node *pool = huffman->pool;
	n = alloc(huffman);
	n->sym = sym;
	n->codelen = codelen;
	id = n - pool;
	while (codelen > 8) {
		codelen -= 8;
		int i = (code >> codelen) & 0xff;
		int nid = curr->children[i];
		if (nid < 0) {
			struct node *n = alloc(huffman);
			curr->children[i] = n - pool;
			curr = n;
		} else {
			curr = &pool[nid];
		}
	}
	pool[id].codelen = codelen;
	shift = 8 - codelen;
	start = (code << shift) & 0xff;
	end = (1 << shift);
	for (i = start; i < start + end; i++) {
		curr->children[i] = id;
	}
}

static int huffman_len(const char *str, int sz)
{
	int i;
	uint64_t n = 0;
	for (i = 0; i < sz; i++)
		n += huffman_codelen[(unsigned char)str[i]];
	return (n + 7) / 8;
}

static int huffman_encode(luaL_Buffer *b, const char *str, int sz)
{
	int i;
	int rembits = 8;
	unsigned char n = 0;
	for (i = 0; i < sz; i++) {
		unsigned char c = str[i];
		uint32_t code = huffman_codes[c];
		int nbits = huffman_codelen[c];
		for (;;) {
			unsigned char t;
			if (rembits > nbits) {
				t = code << (rembits - nbits);
				n |= t;
				rembits -= nbits;
				break;
			}
			t = (code >> (nbits - rembits)) & 0xff;
			n |= t;
			luaL_addchar(b, n);
			n = 0;
			nbits -= rembits;
			rembits = 8;
			if (nbits == 0)
				break;
		}
	}
	if (rembits < 8) {
		uint32_t code = 0x3fffffff;
		int nbits = 30;
		n |= (uint8_t)(code >> (nbits - rembits));
		luaL_addchar(b, n);
	}
	return 0;
}

static int huffman_decode(struct unpack_ctx *uctx, int size, luaL_Buffer *buf)
{
	uint32_t mask;
	const uint8_t *dat, *end;
	uint32_t cur = 0, cbits = 0, sbits = 0;
	struct root *huffman = uctx->huffman;
	struct node *n = &huffman->node;
	struct node *pool = huffman->pool;
	end = uctx->p + size;
	for (dat = uctx->p; dat < end; dat = ++uctx->p) {
		uint32_t b = *dat;
		cur = cur << 8 | b;
		cbits += 8;
		sbits += 8;
		while (cbits >= 8) {
			uint32_t idx = (cur >> (cbits - 8)) & 0xff;
			int nid = n->children[idx];
			if (nid < 0)
				return -1;
			n = &pool[nid];
			if (n->codelen >= 0) {
				luaL_addchar(buf, n->sym);
				cbits -= n->codelen;
				n = &huffman->node;
				sbits = cbits;
			} else {
				cbits -= 8;
			}
		}
	}
	while (cbits > 0) {
		int nid = n->children[(cur << (8 - cbits)) & 0xff];
		if (nid < 0)
			return -1;
		n = &pool[nid];
		if (n->codelen < 0 || n->codelen > (int)cbits)
			break;
		luaL_addchar(buf, n->sym);
		cbits -= n->codelen;
		n = &huffman->node;
		sbits = cbits;
	}
	if (sbits > 7)
		return -1;
	if (mask = (1 << cbits) - 1, (cur & mask) != mask)
		return -1;
	return 0;
}

static int huffman_gc(lua_State *L)
{
	struct root *huffman = luaL_checkudata(L, 1, "http2.huffman");
	if (huffman->pool != NULL) {
		silly_free(huffman->pool);
		huffman->pool = NULL;
		huffman->size = 0;
		huffman->free = 0;
	}
	return 0;
}

static void create_huffman_tree(lua_State *L)
{
	size_t i;
	struct root *huffman = lua_newuserdatauv(L, sizeof(*huffman), 0);
	if (luaL_newmetatable(L, "http2.huffman")) {
		lua_pushcfunction(L, huffman_gc);
		lua_setfield(L, -2, "__gc");
	}
	lua_setmetatable(L, -2);
	huffman->size = 270;
	huffman->free = 0;
	huffman->pool = silly_malloc(sizeof(struct node) * huffman->size);
	memset(huffman->node.children, -1, sizeof(huffman->node.children));
	for (i = 0; i < sizeof(huffman_codes) / sizeof(huffman_codes[0]); i++)
		add_node(huffman, i, huffman_codes[i], huffman_codelen[i]);
}

static inline size_t field_size(const struct lstr *kstr, const struct lstr *vstr)
{
	return kstr->len + vstr->len + 32;
}

static int lhpack_new(lua_State *L)
{
	struct hpack *ctx;
	ctx = lua_newuserdatauv(L, sizeof(*ctx), 1);
	luaL_newmetatable(L, "HPACK");
	lua_setmetatable(L, -2);
	ctx->table_size = 0;
	ctx->hard_limit = luaL_checkinteger(L, 1);
	ctx->soft_limit = ctx->hard_limit;
	ctx->queue_head = ctx->queue_tail = 1;
	ctx->evict_count = 0;
	lua_createtable(L, ctx->hard_limit / 32, ctx->hard_limit / 32);
	lua_setiuservalue(L, -2, 1);
	return 1;
}

static void write_varint(luaL_Buffer *b, uint8_t flag, uint32_t I, int bits)
{
	uint32_t max = ((1 << bits) - 1);
	if (I < max) {
		uint8_t n = I | (uint8_t)(flag << bits);
		luaL_addchar(b, n);
	} else {
		luaL_addchar(b, max | (uint8_t)(flag << bits));
		I = I - max;
		while (I >= 128) {
			luaL_addchar(b, (I & 0x7f) | 0x80);
			I = I / 128;
		}
		luaL_addchar(b, I);
	}
}

static inline uint32_t dynamic_id(struct hpack *ctx, int id)
{
	int size = ctx->queue_head;
	assert(size > id);
	return (size - id) + STATIC_TBL_SIZE;
}

static inline uint32_t dynamic_index(struct hpack *ctx, int id)
{
	int size = ctx->queue_head;
	assert(size > (id - STATIC_TBL_SIZE));
	return size - (id - STATIC_TBL_SIZE);
}

static inline void write_index_kv(luaL_Buffer *b, uint32_t id)
{
	write_varint(b, 0x01, id, 7);
}

static inline void write_literal(luaL_Buffer *b, const struct lstr *str)
{
	size_t len = huffman_len(str->str, str->len);
	if (len < str->len) {
		write_varint(b, 0x1, len, 7);
		huffman_encode(b, str->str, str->len);
	} else {
		write_varint(b, 0x0, str->len, 7);
		luaL_addlstring(b, str->str, str->len);
	}
}

static inline void write_ik_sv(luaL_Buffer *b, uint32_t kid, const struct lstr *vstr,
			       int cache)
{
	if (cache) {
		write_varint(b, 0x01, kid, 6);
	} else {
		write_varint(b, 0x0, kid, 4);
	}
	write_literal(b, vstr);
}

static inline void write_sk_sv(luaL_Buffer *b, const struct lstr *ks,
			       const struct lstr *vs, int cache)
{
	if (cache) {
		luaL_addchar(b, 0x40);
	} else {
		luaL_addchar(b, 0);
	}
	write_literal(b, ks);
	write_literal(b, vs);
}

static inline void push_kv(lua_State *L, const struct lstr *kstr, const struct lstr *vstr)
{
	luaL_Buffer b;
	luaL_buffinit(L, &b);
	luaL_addlstring(&b, kstr->str, kstr->len);
	luaL_addlstring(&b, ": ", 2);
	luaL_addlstring(&b, vstr->str, vstr->len);
	luaL_pushresult(&b);
}

static void prune(lua_State *L, struct hpack *ctx, int dyna)
{
	int idx = 0;
	int i, type;
	for (i = ctx->queue_tail; i < ctx->queue_head; i++) {
		++idx;
		type = lua_geti(L, dyna, i);
		if (type == LUA_TTABLE) {
			struct lstr kstr, vstr;
			lua_geti(L, -1, 1);
			kstr.str = lua_tolstring(L, -1, &kstr.len);
			lua_geti(L, -2, 2);
			vstr.str = lua_tolstring(L, -1, &vstr.len);
			push_kv(L, &kstr, &vstr);
			lua_pushinteger(L, idx);
			lua_settable(L, dyna);
			lua_pop(L, 2);
		} else {
			lua_pushvalue(L, -1);
			lua_pushinteger(L, idx);
			lua_settable(L, dyna);
		}
		lua_seti(L, dyna, idx);
		lua_pushnil(L);
		lua_seti(L, dyna, i);
	}
	ctx->queue_used_min -= (ctx->queue_tail - 1);
	ctx->queue_tail = 1;
	ctx->queue_head = idx + 1;
	ctx->evict_count = 0;
}

static inline int try_evict(lua_State *L, struct hpack *ctx, int dyna, int left)
{
	if ((ctx->soft_limit - ctx->table_size) >= left)
		return 1;
	int min_idx = ctx->queue_used_min;
	while (ctx->queue_tail < min_idx) {
		struct lstr kstr, vstr;
		int i = ctx->queue_tail++;
		int type = lua_geti(L, dyna, i);
		assert(type == LUA_TTABLE);
		lua_geti(L, -1, 1);
		kstr.str = lua_tolstring(L, -1, &kstr.len);
		lua_geti(L, -2, 2);
		vstr.str = lua_tolstring(L, -1, &vstr.len);

		push_kv(L, &kstr, &vstr);
		lua_pushnil(L);
		lua_settable(L, dyna);

		lua_pop(L, 3);

		lua_pushnil(L);
		lua_seti(L, dyna, i);
		++ctx->evict_count;
		ctx->table_size -= field_size(&kstr, &vstr);
	}
	int en = ctx->evict_count;
	if (en > (ctx->queue_head / 2) && en > 64)
		prune(L, ctx, dyna);
	return (ctx->soft_limit - ctx->table_size) >= left;
}

static inline int add_to_table(lua_State *L, struct hpack *ctx, int dyna, int k,
			       int v, int kv, int fsz)
{
	if (!try_evict(L, ctx, dyna, fsz))
		return 0;
	int idx = ctx->queue_head++;
	lua_createtable(L, 2, 0);
	lua_pushvalue(L, k);
	lua_seti(L, -2, 1);
	lua_pushvalue(L, v);
	lua_seti(L, -2, 2);
	lua_seti(L, dyna, idx);

	lua_pushvalue(L, kv);
	lua_pushinteger(L, idx);
	lua_settable(L, dyna);

	ctx->table_size += fsz;
	return 1;
}

static inline void pack_field(lua_State *L, struct pack_ctx *pctx)
{
	int top;
	int cancache;
	luaL_Buffer *b = &pctx->b;
	struct hpack *ctx = pctx->hpack;
	int fsz = field_size(&pctx->kstr, &pctx->vstr);
	cancache = fsz < HTTP2_HEADER_SIZE;
	top = lua_gettop(L);
	if (cancache) { //try index key and value
		int type;
		push_kv(L, &pctx->kstr, &pctx->vstr);

		lua_pushvalue(L, -1);
		type = lua_gettable(L, pctx->stat);
		if (type == LUA_TNUMBER) {
			lua_Integer id = lua_tointeger(L, -1);
			lua_settop(L, top);
			write_index_kv(b, id);
			return;
		}
		lua_pop(L, 1);

		lua_pushvalue(L, -1);
		type = lua_gettable(L, pctx->dyna);
		if (type == LUA_TNUMBER) {
			int idx = lua_tointeger(L, -1);
			lua_settop(L, top);
			int id = dynamic_id(ctx, idx);
			if (idx < ctx->queue_used_min)
				ctx->queue_used_min = idx;
			write_index_kv(b, id);
			return;
		}
		lua_pop(L, 1);
	}
	if (cancache) {
		cancache = add_to_table(L, ctx, pctx->dyna,
			pctx->kstk, pctx->vstk, top+1, fsz);
	}
	lua_pushvalue(L, pctx->kstk);
	if (lua_gettable(L, pctx->stat) == LUA_TNUMBER) {
		int id = lua_tointeger(L, -1);
		lua_settop(L, top);
		write_ik_sv(b, id, &pctx->vstr, cancache);
	} else {
		lua_settop(L, top);
		write_sk_sv(b, &pctx->kstr, &pctx->vstr, cancache);
	}
	return;
}

static inline void copy_str_to_stack(lua_State *L, int from, int to, struct lstr *str)
{
	str->str = luaL_tolstring(L, from, &str->len);
	lua_copy(L, -1, to);
}

//hpack.pack(ctx, header)
static int lhpack_pack(lua_State *L)
{
	int i, argc, top;
	int kstk, vstk, kbackup, vbackup;
	struct pack_ctx pctx;
	pctx.hpack = luaL_checkudata(L, 1, "HPACK");
	pctx.hpack->queue_used_min = pctx.hpack->queue_head;
	argc = lua_gettop(L);
	lua_pushvalue(L, lua_upvalueindex(1)); //static_table
	lua_getiuservalue(L, 1, 1);            //dynamic_table
	pctx.stat = argc + 1;
	pctx.dyna = pctx.stat + 1;
	lua_settop(L, pctx.dyna+4);
	kbackup = pctx.dyna+1;
	vbackup = pctx.dyna+2;
	kstk = pctx.dyna+3;
	vstk = pctx.dyna+4;
	luaL_buffinit(L, &pctx.b);
	top = lua_gettop(L);
	lua_checkstack(L, LUA_MINSTACK);
	for (i = 3; i < argc; i += 2) {
		pctx.kstk = i;
		pctx.vstk = i + 1;
		pctx.kstr.str = luaL_tolstring(L, pctx.kstk, &pctx.kstr.len);
		pctx.vstr.str = luaL_tolstring(L, pctx.vstk, &pctx.vstr.len);
		pack_field(L, &pctx);
		lua_settop(L, top); 		// keep the luaL_buffer on the top
	}

	if (lua_type(L, 2) != LUA_TNIL) {
		lua_pushnil(L); //next key
		pctx.kstk = kstk;
		pctx.vstk = vstk;
		while (lua_next(L, 2) != 0) {
			lua_copy(L, top+1, kbackup);	//backup the key
			lua_copy(L, top+2, vbackup);	//backup the value
			copy_str_to_stack(L, kbackup, kstk, &pctx.kstr);
			lua_settop(L, top);
			if (lua_type(L, vbackup) == LUA_TTABLE) {
				int n = lua_rawlen(L, vbackup);
				for (int i = 1; i <= n; i++) {
					lua_rawgeti(L, vbackup, i);
					copy_str_to_stack(L, -1, vstk, &pctx.vstr);
					lua_settop(L, top);
					// when call pack_field, should keep can't grow the stack
					pack_field(L, &pctx);
				}
			} else {
				copy_str_to_stack(L, vbackup, vstk, &pctx.vstr);
				lua_settop(L, top);
				// when call pack_field, should keep can't grow the stack
				pack_field(L, &pctx);
			}
			lua_pushvalue(L, kbackup);
		}
	}
	luaL_pushresult(&pctx.b);
	return 1;
}

static void concat_table(lua_State *L, luaL_Buffer *b, int t)
{
	int i = 0;
	for (;;) {
		if (lua_geti(L, t, ++i) == LUA_TNIL) {
			lua_pop(L, 1);
			break;
		}
		luaL_addvalue(b);
	}
}

static int read_varint(struct unpack_ctx *ctx, int bits)
{
	int M = 0;
	unsigned int max, I;
	if (ctx->p >= ctx->e)
		return 0;
	I = *ctx->p++;
	max = (1 << bits) - 1;
	ctx->flag = (I >> bits);
	I = I & max;
	if (I >= max) {
		while (ctx->p < ctx->e) {
			unsigned char B = *ctx->p++;
			I = I + ((B & 0x7f) << M);
			if ((B & 0x80) == 0x00)
				break;
			M = M + 7;
		}
	}
	return I;
}

static int push_ik(lua_State *L, struct unpack_ctx *uctx, int id)
{
	int tx, type;
	if (id < STATIC_TBL_SIZE) {
		tx = uctx->stat;
	} else {
		tx = uctx->dyna;
		id = dynamic_index(uctx->hpack, id);
	}
	type = lua_geti(L, tx, id);
	switch (type) {
	case LUA_TSTRING:
		break;
	case LUA_TTABLE:
		lua_geti(L, -1, 1);
		lua_replace(L, -2);
		break;
	default:
		return -1;
	}
	return 0;
}

static int push_sv(lua_State *L, struct unpack_ctx *uctx)
{
	int ret, len;
	len = read_varint(uctx, 7);
	if (uctx->p + len > uctx->e)
		return -1;
	if (uctx->flag == 1) { //huffman decode
		luaL_Buffer b;
		luaL_buffinit(L, &b);
		if ((ret = huffman_decode(uctx, len, &b)) < 0)
			return ret;
		luaL_pushresult(&b);
	} else {
		lua_pushlstring(L, (const char *)uctx->p, len);
		uctx->p += len;
	}
	return 0;
}

static int read_index_kv(lua_State *L, struct unpack_ctx *uctx)
{
	int tx, type;
	int id = read_varint(uctx, 7);
	if (id <= STATIC_TBL_SIZE) {
		tx = uctx->stat;
	} else {
		tx = uctx->dyna;
		id = dynamic_index(uctx->hpack, id);
	}
	type = lua_geti(L, tx, id);
	if (type != LUA_TTABLE)
		return -1;
	lua_geti(L, -1, 1);
	lua_geti(L, -2, 2);
	return 0;
}

static int read_ik_sv(lua_State *L, struct unpack_ctx *uctx, int bits)
{
	int ret;
	unsigned char n = *uctx->p;
	int id = n & ((1 << bits) - 1);
	if (id != 0) {
		id = read_varint(uctx, bits);
		ret = push_ik(L, uctx, id);
		if (ret < 0)
			return ret;
	} else {
		++uctx->p;
		ret = push_sv(L, uctx);
		if (ret < 0)
			return ret;
	}
	ret = push_sv(L, uctx);
	if (ret < 0)
		return ret;
	return 0;
}

//hpack.unpack(ctx, header)
static int lhpack_unpack(lua_State *L)
{
	int htbl, top;
	luaL_Buffer b;
	struct unpack_ctx uctx;
	uctx.hpack = luaL_checkudata(L, 1, "HPACK");
	uctx.hpack->queue_used_min = uctx.hpack->queue_head;
	uctx.huffman = lua_touserdata(L, lua_upvalueindex(2));
	if (lua_type(L, 2) != LUA_TTABLE) {
		size_t sz;
		uctx.p = (const unsigned char *)luaL_checklstring(L, 2, &sz);
		uctx.e = uctx.p + sz;
	} else {
		luaL_buffinit(L, &b);
		concat_table(L, &b, 2);
		uctx.p = (const unsigned char *)luaL_buffaddr(&b);
		uctx.e = uctx.p + luaL_bufflen(&b);
	}
	//try predict the header hash size
	lua_createtable(L, 0, 64);
	htbl = lua_gettop(L);
	lua_pushvalue(L, lua_upvalueindex(1));
	lua_getiuservalue(L, 1, 1);
	uctx.stat = htbl + 1;
	uctx.dyna = htbl + 2;
	top = lua_gettop(L);
	while (uctx.p < uctx.e) {
		int ret;
		unsigned char n = *uctx.p;
		lua_settop(L, top);
		if ((n & 0x80) == 0x80) {
			if ((ret = read_index_kv(L, &uctx)) < 0) //bit7
				return 0;
		} else if ((n & 0xc0) == 0x40) { //bit6
			int stk;
			struct lstr kstr, vstr;
			if ((ret = read_ik_sv(L, &uctx, 6)) < 0)
				return 0;
			kstr.str = lua_tolstring(L, -2, &kstr.len);
			vstr.str = lua_tolstring(L, -1, &vstr.len);
			push_kv(L, &kstr, &vstr);
			stk = lua_absindex(L, -3);
			add_to_table(L, uctx.hpack, uctx.dyna, stk, stk + 1,
				     stk + 2, field_size(&kstr, &vstr));
			lua_pop(L, 1);
		} else if ((n & 0xf0) == 0x0 || (n & 0xf0) == 0x10) { //bit4
			if ((ret = read_ik_sv(L, &uctx, 4)) < 0)
				return 0;
		} else if ((n & 0xe0) == 0x20) { //bit5
			int len = read_varint(&uctx, 5);
			uctx.hpack->soft_limit = len;
			try_evict(L, uctx.hpack, uctx.dyna, 0);
			continue;
		}
		lua_pushvalue(L, -2); // push key
		int type = lua_gettable(L, htbl);
		switch (type) {
		case LUA_TSTRING:
			lua_createtable(L, 0, 2);
			lua_pushvalue(L, -2);
			lua_rawseti(L, -2, 1);
			lua_pushvalue(L, -3);
			lua_rawseti(L, -2, 2);
			lua_replace(L, -3);
			break;
		case LUA_TTABLE: // hk = header[k]; hk[#hk+1] = v
			lua_pushvalue(L, -2);
			lua_rawseti(L, -2, lua_rawlen(L, -2) + 1);
			break;
		default:
			break;
		}
		lua_pop(L, 1);
		lua_settable(L, htbl);
	}
	lua_settop(L, htbl);
	return 1;
}

static int lhpack_hardlimit(lua_State *L)
{
	struct hpack *hpack;
	hpack = luaL_checkudata(L, 1, "HPACK");
	hpack->hard_limit = luaL_checkinteger(L, 2);
	hpack->soft_limit = hpack->hard_limit;
	lua_getiuservalue(L, 1, 1);
	try_evict(L, hpack, lua_gettop(L), 0);
	lua_pop(L, 1);
	return 0;
}

static void create_static_table(lua_State *L)
{
	size_t i, t;
	lua_createtable(L, 61, 61);
	t = lua_gettop(L);
	for (i = 0; i < sizeof(static_tbl) / sizeof(static_tbl[0]); i++) {
		int type;
		int id = i + 1;
		const char *k = static_tbl[i][0];
		const char *v = static_tbl[i][1];
		lua_pushstring(L, k);
		type = lua_gettable(L, t);
		lua_pop(L, 1);
		if (type == LUA_TNIL) {
			lua_pushstring(L, k);
			lua_seti(L, t, id);
			lua_pushstring(L, k);
			lua_pushinteger(L, id);
			lua_settable(L, t);
		}
		if (v != NULL) {
			struct lstr kstr, vstr;
			//local t = {k, v}
			lua_createtable(L, 2, 0);
			lua_pushstring(L, k);
			lua_seti(L, -2, 1);
			lua_pushstring(L, v);
			lua_seti(L, -2, 2);
			//static_table[id] = t
			lua_seti(L, t, id);
			//static_tbl[format("%s %s", k, v)] = id
			kstr.str = k;
			kstr.len = strlen(k);
			vstr.str = v;
			vstr.len = strlen(v);
			push_kv(L, &kstr, &vstr);
			lua_pushinteger(L, id);
			lua_settable(L, t);
		}
	}
}

#ifdef SILLY_TEST
static int dbg_evictcount(lua_State *L)
{
	struct hpack *hpack = luaL_checkudata(L, 1, "HPACK");
	lua_pushinteger(L, hpack->evict_count);
	return 1;
}

static int dbg_stringid(lua_State *L)
{
	int type;
	lua_getiuservalue(L, 1, 1); //dynamic_table
	int dyna = lua_gettop(L);
	struct lstr kstr, vstr;
	kstr.str = luaL_tolstring(L, 2, &kstr.len);
	vstr.str = luaL_tolstring(L, 3, &vstr.len);
	push_kv(L, &kstr, &vstr);

	lua_pushvalue(L, -1);
	type = lua_gettable(L, dyna);
	if (type != LUA_TNUMBER)
		lua_pushnil(L);
	return 1;
}

#endif

int luaopen_core_http2_hpack(lua_State *L)
{
	luaL_Reg tbl[] = {
		{ "new",            lhpack_new       },
		{ "pack",           lhpack_pack      },
		{ "unpack",         lhpack_unpack    },
		{ "hardlimit",      lhpack_hardlimit },
#ifdef SILLY_TEST
		{ "dbg_evictcount", dbg_evictcount   },
		{ "dbg_stringid",   dbg_stringid     },
#endif
		{ NULL,             NULL             },
	};
	luaL_newlibtable(L, tbl);
	create_static_table(L);
	create_huffman_tree(L);
	luaL_setfuncs(L, tbl, 2);
	return 1;
}

///////////////////////////framebuilder///////////////////////////

#define FRAME_DATA 0
#define FRAME_HEADERS 1
#define FRAME_RST 3
#define FRAME_SETTINGS 4
#define FRAME_WINUPDATE 8
#define FRAME_CONTINUATION 9

#define END_STREAM 0x01
#define END_HEADERS 0x04

static inline void write_frame_header(char *p, int len, int type, int flag,
				      unsigned int id)
{
	//frame.length
	p[0] = (char)(len >> 16);
	p[1] = (char)(len >> 8);
	p[2] = (char)len;
	//frame.type
	p[3] = type;
	//frame.flag
	p[4] = flag;
	//frame.stream id
	p[5] = (char)(id >> 24);
	p[6] = (char)(id >> 16);
	p[7] = (char)(id >> 8);
	p[8] = (char)id;
}

//build(id, framesize, header, endstream)
static int lframe_build_header(lua_State *L)
{
	luaL_Buffer b;
	char *p;
	int type;
	size_t sz, need;
	const char *hdr;
	unsigned int flag;
	unsigned int id, framesize;
	id = luaL_checkinteger(L, 1);
	framesize = luaL_checkinteger(L, 2);
	hdr = luaL_checklstring(L, 3, &sz);
	need = sz + (sz + framesize - 1) / framesize * FRAME_HDR_SIZE;
	flag = lua_toboolean(L, 4) ? END_STREAM : 0;
	type = FRAME_HEADERS;
	p = luaL_buffinitsize(L, &b, need + FRAME_HDR_SIZE);
	while (sz > framesize) {
		write_frame_header(p, framesize, type, flag, id);
		p += FRAME_HDR_SIZE;
		memcpy(p, hdr, framesize);
		p += framesize;
		hdr += framesize;
		sz -= framesize;
		flag = 0;
		type = FRAME_CONTINUATION;
	}
	write_frame_header(p, sz, FRAME_HEADERS, flag | END_HEADERS, id);
	p += FRAME_HDR_SIZE;
	memcpy(p, hdr, sz);
	p += sz;
	luaL_pushresultsize(&b, p - luaL_buffaddr(&b));
	return 1;
}

//build(id, framesize, body, endstream)
static int lframe_build_body(lua_State *L)
{
	char *p;
	const char *dat;
	size_t sz, need, framesize;
	unsigned int id, flag;
	luaL_Buffer b;
	id = luaL_checkinteger(L, 1);
	framesize = luaL_checkinteger(L, 2);
	dat = luaL_checklstring(L, 3, &sz);
	flag = lua_toboolean(L, 4) ? END_STREAM : 0;
	need = sz + (sz + framesize - 1) / framesize * FRAME_HDR_SIZE;
	p = luaL_buffinitsize(L, &b, need + FRAME_HDR_SIZE);
	while (sz > framesize) {
		write_frame_header(p, framesize, FRAME_DATA, 0, id);
		p += FRAME_HDR_SIZE;
		memcpy(p, dat, framesize);
		p += framesize;
		dat += framesize;
		sz -= framesize;
	}
	write_frame_header(p, sz, FRAME_DATA, flag, id);
	p += FRAME_HDR_SIZE;
	memcpy(p, dat, sz);
	p += sz;
	luaL_pushresultsize(&b, p - luaL_buffaddr(&b));
	return 1;
}

//build(flag, id, val, id, val,...)
static int lframe_build_setting(lua_State *L)
{
	char *p;
	luaL_Buffer b;
	int flag, i, need;
	int top = lua_gettop(L);
	if (top % 2 != 1)
		return luaL_error(L, "setting should in pairs");
	flag = luaL_checkinteger(L, 1);
	need = ((top - 1) / 2) * 6;
	p = luaL_buffinitsize(L, &b, need + FRAME_HDR_SIZE);
	write_frame_header(p, need, FRAME_SETTINGS, flag, 0);
	p += FRAME_HDR_SIZE;
	for (i = 2; i < top; i += 2) {
		unsigned int id = luaL_checkinteger(L, i);
		unsigned int val = luaL_checkinteger(L, i + 1);
		*p++ = (unsigned char)(id >> 8);
		*p++ = (unsigned char)(id);
		*p++ = (unsigned char)(val >> 24);
		*p++ = (unsigned char)(val >> 16);
		*p++ = (unsigned char)(val >> 8);
		*p++ = (unsigned char)(val);
	}
	luaL_pushresultsize(&b, p - luaL_buffaddr(&b));
	return 1;
}

static void write_int(char *p, unsigned int size)
{
	p[0] = (unsigned char)(size >> 24);
	p[1] = (unsigned char)(size >> 16);
	p[2] = (unsigned char)(size >> 8);
	p[3] = (unsigned char)(size);
}

//build(id, flag, size)
static int lframe_build_winupdate(lua_State *L)
{
	char *p;
	luaL_Buffer b;
	unsigned int id = luaL_checkinteger(L, 1);
	int flag = luaL_checkinteger(L, 2);
	unsigned int size = luaL_checkinteger(L, 3);
	p = luaL_buffinitsize(L, &b, (4 + FRAME_HDR_SIZE) * 2);
	write_frame_header(p, 4, FRAME_WINUPDATE, flag, id);
	p += FRAME_HDR_SIZE;
	write_int(p, size);
	p += 4;
	if (id != 0) {
		write_frame_header(p, 4, FRAME_WINUPDATE, 0, 0);
		p += FRAME_HDR_SIZE;
		write_int(p, size);
		p += 4;
	}
	luaL_pushresultsize(&b, p - luaL_buffaddr(&b));
	return 1;
}

//rst(id, errorcode)
static int lframe_build_rst(lua_State *L)
{
	char *p;
	luaL_Buffer b;
	unsigned int id = luaL_checkinteger(L, 1);
	int errorcode = luaL_checkinteger(L, 2);
	p = luaL_buffinitsize(L, &b, FRAME_HDR_SIZE + 4);
	write_frame_header(p, 4, FRAME_RST, 0, id);
	p += FRAME_HDR_SIZE;
	write_int(p, errorcode);
	p += 4;
	luaL_pushresultsize(&b, p - luaL_buffaddr(&b));
	return 1;
}

int luaopen_core_http2_framebuilder(lua_State *L)
{
	luaL_Reg tbl[] = {
		{ "header",    lframe_build_header    },
		{ "body",      lframe_build_body      },
		{ "setting",   lframe_build_setting   },
		{ "winupdate", lframe_build_winupdate },
		{ "rst",       lframe_build_rst       },
		{ NULL,        NULL                   }
	};
	luaL_newlib(L, tbl);
	return 1;
}
