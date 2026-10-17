#include <assert.h>
#include <string.h>
#include <stdlib.h>
#include <stdint.h>
#include <lua.h>
#include <lauxlib.h>

#include "silly.h"
#include "http2_table.h"

#define STATIC_TBL_SIZE (61)
#define HPACK_STATIC_UPVALUE (1)
#define HPACK_NAME_UPVALUE (2)
#define HPACK_HUFFMAN_UPVALUE (3)
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

// RFC 7541 Sections 5.2 and 6: integer prefix widths and wire-format flags.
#define HPACK_INDEXED_BITS (7)
#define HPACK_LITERAL_INDEXED_BITS (6)
#define HPACK_LITERAL_UNINDEXED_BITS (4)
#define HPACK_LITERAL_NEVERINDEXED_BITS (4)
#define HPACK_TABLE_SIZE_BITS (5)
#define HPACK_STRING_BITS (7)

#define HPACK_PREFIX_MASK(bits) ((1 << (bits)) - 1)

#define HPACK_IS_INDEXED(B) (((B) & 0x80u) == 0x80u)
#define HPACK_IS_LITERAL_INDEXED(B) (((B) & 0xc0u) == 0x40u)
#define HPACK_IS_LITERAL_UNINDEXED(B) (((B) & 0xf0u) == 0x00u)
#define HPACK_IS_LITERAL_NEVERINDEXED(B) (((B) & 0xf0u) == 0x10u)
#define HPACK_IS_TABLE_SIZE(B) (((B) & 0xe0u) == 0x20u)
#define HPACK_IS_HUFFMAN(B) (((B) & 0x80u) == 0x80u)

// These write the leading integer only; literal/string bytes follow separately.
#define HPACK_WRITE_INDEXED(b, I) \
	write_varint((b), (0x01u << HPACK_INDEXED_BITS), (I), HPACK_INDEXED_BITS)
#define HPACK_WRITE_LITERAL_INDEXED(b, I) \
	write_varint((b), (0x01u << HPACK_LITERAL_INDEXED_BITS), (I), HPACK_LITERAL_INDEXED_BITS)
#define HPACK_WRITE_LITERAL_UNINDEXED(b, I) \
	write_varint((b), (0x00u << HPACK_LITERAL_UNINDEXED_BITS), (I), HPACK_LITERAL_UNINDEXED_BITS)
#define HPACK_WRITE_LITERAL_NEVERINDEXED(b, I) \
	write_varint((b), (0x01u << HPACK_LITERAL_NEVERINDEXED_BITS), (I), HPACK_LITERAL_NEVERINDEXED_BITS)
#define HPACK_WRITE_LITERAL_NAME(b, cache) \
	luaL_addchar((b), (cache) ? 0x40u : 0x00u)
#define HPACK_WRITE_TABLE_SIZE(b, I) \
	write_varint((b), (0x01u << HPACK_TABLE_SIZE_BITS), (I), HPACK_TABLE_SIZE_BITS)
#define HPACK_WRITE_RAW_LENGTH(b, I) \
	write_varint((b), (0x00u << HPACK_STRING_BITS), (I), HPACK_STRING_BITS)
#define HPACK_WRITE_HUFFMAN_LENGTH(b, I) \
	write_varint((b), (0x01u << HPACK_STRING_BITS), (I), HPACK_STRING_BITS)

struct hpack {
	int hard_limit;
	int soft_limit;
	int table_size;
	int queue_head;
	int queue_tail;
	int evict_count;
	int update_pending;
	int update_min;
	int pack_incomplete; // Set until pack returns; Lua errors leave it set.
};

struct unpack_ctx {
	struct root *huffman;
	int names;
	int stat;
	int dyna;
	unsigned int flag; // First-octet flag bits in their wire positions.
	const unsigned char *p;
	const unsigned char *e;
	struct hpack *hpack;
};

struct pack_ctx {
	int stat;
	int names;
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
	for (i = 0; i < ARRAY_SIZE(huffman_codes); i++)
		add_node(huffman, i, huffman_codes[i], huffman_codelen[i]);
}

static inline size_t field_size(size_t ksize, size_t vsize)
{
	// RFC 7541 Section 4.1: count decoded octets, before Huffman encoding.
	return ksize + vsize + 32;
}

static int lhpack_new(lua_State *L)
{
	struct hpack *ctx;
	lua_Integer limit = luaL_checkinteger(L, 1);
	luaL_argcheck(L, limit >= 0 && limit <= INT_MAX, 1, "invalid table size");
	ctx = lua_newuserdatauv(L, sizeof(*ctx), 1);
	luaL_newmetatable(L, "HPACK");
	lua_setmetatable(L, -2);
	ctx->table_size = 0;
	ctx->hard_limit = limit;
	ctx->soft_limit = ctx->hard_limit;
	ctx->queue_head = ctx->queue_tail = 1;
	ctx->evict_count = 0;
	ctx->update_pending = 0;
	ctx->update_min = ctx->hard_limit;
	ctx->pack_incomplete = 0;
	lua_createtable(L, ctx->hard_limit / 32, ctx->hard_limit / 32);
	lua_setiuservalue(L, -2, 1);
	return 1;
}

// flag is already shifted into its position in the first octet.
static void write_varint(luaL_Buffer *b, uint8_t flag, uint32_t I, int bits)
{
	uint32_t max = HPACK_PREFIX_MASK(bits);
	if (I < max) {
		uint8_t n = I | flag;
		luaL_addchar(b, n);
	} else {
		luaL_addchar(b, max | flag);
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
	HPACK_WRITE_INDEXED(b, id);
}

static inline void write_literal(luaL_Buffer *b, const struct lstr *str)
{
	size_t len = huffman_len(str->str, str->len);
	if (len < str->len) {
		HPACK_WRITE_HUFFMAN_LENGTH(b, len);
		huffman_encode(b, str->str, str->len);
	} else {
		HPACK_WRITE_RAW_LENGTH(b, str->len);
		luaL_addlstring(b, str->str, str->len);
	}
}

static inline void write_ik_sv(luaL_Buffer *b, uint32_t kid,
			       const struct lstr *vstr, int cache)
{
	if (cache) {
		HPACK_WRITE_LITERAL_INDEXED(b, kid);
	} else {
		HPACK_WRITE_LITERAL_UNINDEXED(b, kid);
	}
	write_literal(b, vstr);
}

static inline void write_sk_sv(luaL_Buffer *b, const struct lstr *ks,
			       const struct lstr *vs, int cache)
{
	HPACK_WRITE_LITERAL_NAME(b, cache);
	write_literal(b, ks);
	write_literal(b, vs);
}

static inline void push_kv(lua_State *L, const struct lstr *kstr,
			   const struct lstr *vstr)
{
	luaL_Buffer b;
	luaL_buffinit(L, &b);
	// This length is an internal key prefix, not an HPACK wire integer.
	// Names and values are opaque octets, so a delimiter is not sufficient.
	luaL_addlstring(&b, (const char *)&kstr->len, sizeof(kstr->len));
	luaL_addlstring(&b, kstr->str, kstr->len);
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
	ctx->queue_tail = 1;
	ctx->queue_head = idx + 1;
	ctx->evict_count = 0;
}

static inline int try_evict(lua_State *L, struct hpack *ctx, int dyna, int left)
{
	int en;
	if ((ctx->soft_limit - ctx->table_size) >= left)
		return 1;
	// RFC 7541 Sections 4.3 and 4.4: evict oldest entries only until they fit.
	while (ctx->queue_tail < ctx->queue_head && (ctx->soft_limit - ctx->table_size) < left) {
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
		ctx->table_size -= field_size(kstr.len, vstr.len);
	}
	en = ctx->evict_count;
	if (en > (ctx->queue_head / 2) && en > 64)
		prune(L, ctx, dyna);
	return (ctx->soft_limit - ctx->table_size) >= left;
}

static inline int add_to_table(lua_State *L, struct hpack *ctx, int dyna, int k,
			       int v, int kv, int fsz)
{
	int idx;
	if (!try_evict(L, ctx, dyna, fsz))
		return 0;
	idx = ctx->queue_head++;
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
	size_t fsz = field_size(pctx->kstr.len, pctx->vstr.len);
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
			int id = dynamic_id(ctx, idx);
			lua_settop(L, top);
			write_index_kv(b, id);
			return;
		}
		lua_pop(L, 1);
	}
	if (cancache) {
		// A literal without indexing must leave the dynamic table unchanged.
		cancache = fsz <= (size_t)ctx->soft_limit &&
			   add_to_table(L, ctx, pctx->dyna, pctx->kstk, pctx->vstk, top + 1, fsz);
	}
	lua_pushvalue(L, pctx->kstk);
	if (lua_gettable(L, pctx->names) == LUA_TNUMBER) {
		int id = lua_tointeger(L, -1);
		lua_settop(L, top);
		write_ik_sv(b, id, &pctx->vstr, cancache);
	} else {
		lua_settop(L, top);
		write_sk_sv(b, &pctx->kstr, &pctx->vstr, cancache);
	}
	return;
}

static inline void copy_str_to_stack(lua_State *L, int from, int to,
				     struct lstr *str)
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
	argc = lua_gettop(L);
	lua_pushvalue(L, lua_upvalueindex(HPACK_STATIC_UPVALUE)); //static_table
	lua_pushvalue(L, lua_upvalueindex(HPACK_NAME_UPVALUE));   //static names
	lua_getiuservalue(L, 1, 1);            //dynamic_table
	pctx.stat = argc + 1;
	pctx.names = pctx.stat + 1;
	pctx.dyna = pctx.names + 1;
	lua_settop(L, pctx.dyna + 4);
	kbackup = pctx.dyna + 1;
	vbackup = pctx.dyna + 2;
	kstk = pctx.dyna + 3;
	vstk = pctx.dyna + 4;
	luaL_buffinit(L, &pctx.b);
	top = lua_gettop(L);
	lua_checkstack(L, LUA_MINSTACK);
	if (pctx.hpack->pack_incomplete) {
		// The previous block was not returned. Reset both tables before reusing indices.
		try_evict(L, pctx.hpack, pctx.dyna, pctx.hpack->soft_limit);
		pctx.hpack->update_min = 0;
		pctx.hpack->update_pending = 1;
	}
	if (pctx.hpack->update_pending) {
		HPACK_WRITE_TABLE_SIZE(&pctx.b, pctx.hpack->update_min);
		if (pctx.hpack->update_min != pctx.hpack->soft_limit)
			HPACK_WRITE_TABLE_SIZE(&pctx.b, pctx.hpack->soft_limit);
		pctx.hpack->update_pending = 0;
	}
	pctx.kstk = kstk;
	pctx.vstk = vstk;
	pctx.hpack->pack_incomplete = 1;
	for (i = 3; i < argc; i += 2) {
		copy_str_to_stack(L, i, kstk, &pctx.kstr);
		copy_str_to_stack(L, i + 1, vstk, &pctx.vstr);
		lua_settop(L, top); // buffer must be on top before it can grow
		pack_field(L, &pctx);
	}

	if (lua_type(L, 2) != LUA_TNIL) {
		lua_pushnil(L); //next key
		while (lua_next(L, 2) != 0) {
			lua_copy(L, top + 1, kbackup); //backup the key
			lua_copy(L, top + 2, vbackup); //backup the value
			copy_str_to_stack(L, kbackup, kstk, &pctx.kstr);
			lua_settop(L, top);
			if (lua_type(L, vbackup) == LUA_TTABLE) {
				int n = lua_rawlen(L, vbackup);
				for (int i = 1; i <= n; i++) {
					lua_rawgeti(L, vbackup, i);
					copy_str_to_stack(L, -1, vstk,
							  &pctx.vstr);
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
	pctx.hpack->pack_incomplete = 0;
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
	unsigned int M = 0;
	uint32_t max, I;
	if (ctx->p >= ctx->e)
		return -1;
	I = *ctx->p++;
	max = HPACK_PREFIX_MASK(bits);
	ctx->flag = I & ~max;
	I = I & max;
	if (I >= max) {
		for (;;) {
			unsigned char B;
			if (ctx->p >= ctx->e)
				return -1;
			B = *ctx->p++;
			if (M >= 31 || (uint32_t)(B & 0x7f) > ((uint32_t)INT_MAX - I) >> M)
				return -1;
			I += (uint32_t)(B & 0x7f) << M;
			if ((B & 0x80) == 0x00)
				break;
			M += 7;
		}
	}
	return I;
}

static int push_ik(lua_State *L, struct unpack_ctx *uctx, int id)
{
	int tx, type;
	// RFC 7541 Section 2.3.2: Static table index range is [1, 61]
	if (id <= 0)
		return -1;
	if (id <= STATIC_TBL_SIZE) {
		tx = uctx->names;
	} else {
		// RFC 7541 Section 2.3.3: Validate dynamic table index range
		// Valid range: [STATIC_TBL_SIZE + 1, STATIC_TBL_SIZE + (queue_head - queue_tail)]
		int offset = id - STATIC_TBL_SIZE;
		if (offset > (uctx->hpack->queue_head - uctx->hpack->queue_tail))
			return -1;
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
	len = read_varint(uctx, HPACK_STRING_BITS);
	if (len < 0 || (size_t)len > (size_t)(uctx->e - uctx->p))
		return -1;
	if (HPACK_IS_HUFFMAN(uctx->flag)) {
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
	int tx, type, id;
	id = read_varint(uctx, HPACK_INDEXED_BITS);
	// RFC 7541 Section 2.3.2: Static table index range is [1, 61]
	if (id <= 0)
		return -1;
	if (id <= STATIC_TBL_SIZE) {
		lua_geti(L, uctx->names, id);
		lua_geti(L, uctx->stat, id);
		return 0;
	} else {
		// RFC 7541 Section 2.3.3: Validate dynamic table index range
		// Valid range: [STATIC_TBL_SIZE + 1, STATIC_TBL_SIZE + (queue_head - queue_tail)]
		int offset = id - STATIC_TBL_SIZE;
		if (offset > (uctx->hpack->queue_head - uctx->hpack->queue_tail))
			return -1;
		tx = uctx->dyna;
		id = dynamic_index(uctx->hpack, id);
	}
	type = lua_geti(L, tx, id);
	if (type == LUA_TTABLE) {
		lua_geti(L, -1, 1);
		lua_geti(L, -2, 2);

	} else {
		return -1;
	}
	return 0;
}

static int read_ik_sv(lua_State *L, struct unpack_ctx *uctx, int bits)
{
	int ret;
	unsigned char n = *uctx->p;
	int id = n & HPACK_PREFIX_MASK(bits);
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

//hpack.unpack(ctx, data, header_list, limit?) -> success, limited?
// limit counts decoded name/value octets plus 32 per field; omitted means no list limit.
static int lhpack_unpack(lua_State *L)
{
	int i;
	int htbl, top;
	int limited = 0;
	lua_Integer limit;
	lua_Unsigned list_size = 0;
	luaL_Buffer b;
	struct unpack_ctx uctx;
	int seen_header_field = 0; // RFC 7541 Section 4.2: Track if we've seen any header fields

	limit = luaL_optinteger(L, 4, LUA_MAXINTEGER);
	luaL_argcheck(L, limit >= 0, 4, "invalid header list size");
	uctx.hpack = luaL_checkudata(L, 1, "HPACK");
	uctx.huffman = lua_touserdata(L, lua_upvalueindex(HPACK_HUFFMAN_UPVALUE));
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
	htbl = 3;
	top = lua_gettop(L);
	lua_pushvalue(L, lua_upvalueindex(HPACK_STATIC_UPVALUE));
	lua_pushvalue(L, lua_upvalueindex(HPACK_NAME_UPVALUE));
	lua_getiuservalue(L, 1, 1);
	uctx.stat = top + 1;
	uctx.names = top + 2;
	uctx.dyna = top + 3;
	top += 3;
	i = lua_rawlen(L, htbl);
	while (uctx.p < uctx.e) {
		int ret;
		size_t size;
		unsigned char n = *uctx.p;
		lua_settop(L, top);
		if (HPACK_IS_INDEXED(n)) {
			if ((ret = read_index_kv(L, &uctx)) < 0) {
				lua_pushboolean(L, 0);
				return 1;
			}
			seen_header_field = 1;
		} else if (HPACK_IS_LITERAL_INDEXED(n)) {
			int stk;
			size_t fsz;
			struct lstr kstr, vstr;
			if ((ret = read_ik_sv(L, &uctx, HPACK_LITERAL_INDEXED_BITS)) < 0) {
				lua_pushboolean(L, 0);
				return 1;
			}
			kstr.str = lua_tolstring(L, -2, &kstr.len);
			vstr.str = lua_tolstring(L, -1, &vstr.len);
			fsz = field_size(kstr.len, vstr.len);
			// An oversized indexed literal clears the table without needing a cache key.
			if (fsz > (size_t)uctx.hpack->soft_limit) {
				try_evict(L, uctx.hpack, uctx.dyna, uctx.hpack->soft_limit);
			} else {
				push_kv(L, &kstr, &vstr);
				stk = lua_absindex(L, -3);
				add_to_table(L, uctx.hpack, uctx.dyna, stk, stk + 1, stk + 2, fsz);
				lua_pop(L, 1);
			}
			seen_header_field = 1;
		} else if (HPACK_IS_LITERAL_UNINDEXED(n) || HPACK_IS_LITERAL_NEVERINDEXED(n)) {
			if ((ret = read_ik_sv(L, &uctx, HPACK_LITERAL_UNINDEXED_BITS)) < 0) {
				lua_pushboolean(L, 0);
				return 1;
			}
			seen_header_field = 1;
		} else if (HPACK_IS_TABLE_SIZE(n)) {
			int len;
			// RFC 7541 Section 4.2: Dynamic table size update MUST occur at the beginning
			if (seen_header_field) {
				lua_pushboolean(L, 0);
				return 1;
			}
			len = read_varint(&uctx, HPACK_TABLE_SIZE_BITS);
			// RFC 7541 Section 6.3: The new maximum size MUST be lower than or equal
			// to the limit determined by the protocol (SETTINGS_HEADER_TABLE_SIZE)
			if (len < 0 || len > uctx.hpack->hard_limit) {
				lua_pushboolean(L, 0);
				return 1;
			}
			uctx.hpack->soft_limit = len;
			try_evict(L, uctx.hpack, uctx.dyna, 0);
			continue;
		}
		// Keep decoding and updating the table after the output limit is reached.
		if (limited)
			continue;
		size = field_size(lua_rawlen(L, -2), lua_rawlen(L, -1));
		if ((lua_Unsigned)size > (lua_Unsigned)limit - list_size) {
			limited = 1;
			continue;
		}
		list_size += size;
		lua_pushvalue(L, -2); // push key
		lua_rawseti(L, htbl, ++i);
		lua_pushvalue(L, -1); // push value
		lua_rawseti(L, htbl, ++i);
		lua_pop(L, 2); //pop key and value
	}
	// RFC 7540 Section 4.3: All header block data must be consumed
	// If there's remaining unparsed data, the header block is malformed
	if (limited) {
		lua_pushboolean(L, 0);
		lua_pushboolean(L, 1);
		return 2;
	}
	lua_pushboolean(L, uctx.p == uctx.e);
	return 1;
}

static int lhpack_hardlimit(lua_State *L)
{
	struct hpack *hpack;
	lua_Integer limit;
	hpack = luaL_checkudata(L, 1, "HPACK");
	limit = luaL_checkinteger(L, 2);
	luaL_argcheck(L, limit >= 0 && limit <= INT_MAX, 2, "invalid table size");
	if (limit == hpack->hard_limit)
		return 0;
	if (!hpack->update_pending || limit < hpack->update_min)
		hpack->update_min = limit;
	hpack->update_pending = 1;
	hpack->hard_limit = limit;
	hpack->soft_limit = hpack->hard_limit;
	lua_getiuservalue(L, 1, 1);
	try_evict(L, hpack, lua_gettop(L), 0);
	lua_pop(L, 1);
	return 0;
}

static void create_static_table(lua_State *L)
{
	int i, stat, names;
	// Both tables have 61 reverse indices; name->first-index has <=61 keys.
	lua_createtable(L, STATIC_TBL_SIZE, STATIC_TBL_SIZE);
	stat = lua_gettop(L);
	lua_createtable(L, STATIC_TBL_SIZE, STATIC_TBL_SIZE);
	names = lua_gettop(L);
	for (i = 0; i < STATIC_TBL_SIZE; i++) {
		int id = i + 1;
		struct lstr kstr, vstr;
		const char *k = static_tbl[i][0];
		const char *v = static_tbl[i][1];
		if (v == NULL)
			v = "";
		lua_pushstring(L, k);
		lua_seti(L, names, id);
		lua_pushstring(L, k);
		if (lua_gettable(L, names) == LUA_TNIL) {
			lua_pushstring(L, k);
			lua_pushinteger(L, id);
			lua_settable(L, names);
		}
		lua_pop(L, 1);
		lua_pushstring(L, v);
		lua_seti(L, stat, id);
		kstr.str = k;
		kstr.len = strlen(k);
		vstr.str = v;
		vstr.len = strlen(v);
		push_kv(L, &kstr, &vstr);
		lua_pushinteger(L, id);
		lua_settable(L, stat);
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
	int type, dyna;
	struct lstr kstr, vstr;
	lua_getiuservalue(L, 1, 1); //dynamic_table
	dyna = lua_gettop(L);
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

SILLY_MOD_API int luaopen_silly_http2_hpack(lua_State *L)
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
	luaL_setfuncs(L, tbl, 3);
	return 1;
}

///////////////////////////framebuilder///////////////////////////

#define FRAME_DATA 0
#define FRAME_HEADERS 1
#define FRAME_RST 3
#define FRAME_SETTINGS 4
#define FRAME_PING 6
#define FRAME_GOAWAY 7
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

//build(id, framesize, body, endstream, offset, length)
static int lframe_build_body(lua_State *L)
{
	char *p;
	const char *dat;
	int offset, len;
	size_t sz, need, framesize, remaining;
	unsigned int id, flag;
	luaL_Buffer b;
	id = luaL_checkinteger(L, 1);
	framesize = luaL_checkinteger(L, 2);
	dat = luaL_checklstring(L, 3, &sz);
	flag = lua_toboolean(L, 4) ? END_STREAM : 0;
	offset = luaL_optinteger(L, 5, 0);
	len = luaL_optinteger(L, 6, sz - offset);
	luaL_argcheck(L, offset >= 0 && len >= 0 &&
		       (size_t)offset + (size_t)len <= sz,
		       4, "invalid offset or length");
	dat += offset;  // Advance to the offset position
	remaining = (size_t)len;
	need = remaining + (remaining + framesize - 1) / framesize * FRAME_HDR_SIZE;
	p = luaL_buffinitsize(L, &b, need + FRAME_HDR_SIZE);
	while (remaining > framesize) {
		write_frame_header(p, framesize, FRAME_DATA, 0, id);
		p += FRAME_HDR_SIZE;
		memcpy(p, dat, framesize);
		p += framesize;
		dat += framesize;
		remaining -= framesize;
	}
	write_frame_header(p, remaining, FRAME_DATA, flag, id);
	p += FRAME_HDR_SIZE;
	memcpy(p, dat, remaining);
	p += remaining;
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

//goaway(last_stream_id, errorcode)
static int lframe_build_goaway(lua_State *L)
{
	char *p;
	luaL_Buffer b;
	unsigned int last_stream_id = luaL_checkinteger(L, 1);
	int errorcode = luaL_checkinteger(L, 2);
	p = luaL_buffinitsize(L, &b, FRAME_HDR_SIZE + 8);
	write_frame_header(p, 8, FRAME_GOAWAY, 0, 0); // GOAWAY is always on stream 0
	p += FRAME_HDR_SIZE;
	write_int(p, last_stream_id);
	p += 4;
	write_int(p, errorcode);
	p += 4;
	luaL_pushresultsize(&b, p - luaL_buffaddr(&b));
	return 1;
}

SILLY_MOD_API int luaopen_silly_http2_framebuilder(lua_State *L)
{
	luaL_Reg tbl[] = {
		{ "header",    lframe_build_header    },
		{ "body",      lframe_build_body      },
		{ "setting",   lframe_build_setting   },
		{ "winupdate", lframe_build_winupdate },
		{ "rst",       lframe_build_rst       },
		{ "goaway",    lframe_build_goaway    },
		{ NULL,        NULL                   }
	};
	luaL_newlib(L, tbl);
	return 1;
}
