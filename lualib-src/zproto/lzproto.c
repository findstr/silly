#include <stdio.h>
#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "lua.h"
#include "lualib.h"
#include "lauxlib.h"
#include "zproto.h"

#define MAX_RECURSIVE (64)

#if LUA_VERSION_NUM < 502

#define lua_rawlen	lua_objlen

#ifndef luaL_checkversion
#define luaL_checkversion(L)	(void)0
#endif

#ifndef luaL_newlib
#define luaL_newlib(L,l)  \
	(luaL_checkversion(L),\
	lua_createtable(L, 0, sizeof(l)/sizeof((l)[0]) - 1),\
	luaL_setfuncs(L,l,0))
	/*
** Copy from lua5.3
** set functions from list 'l' into table at top - 'nup'; each
** function gets the 'nup' elements at the top as upvalues.
** Returns with only the table at the stack.
*/
LUALIB_API void
luaL_setfuncs (lua_State *L, const luaL_Reg *l, int nup) {
	luaL_checkstack(L, nup, "too many upvalues");
	/* fill the table with given functions */
	for (; l->name != NULL; l++) {
		int i;
		for (i = 0; i < nup; i++)  /* copy upvalues to the top */
			lua_pushvalue(L, -nup);
		lua_pushcclosure(L, l->func, nup);  /* closure with those upvalues */
		lua_setfield(L, -(nup + 2), l->name);
	}
	lua_pop(L, nup);  /* remove upvalues */
}
#endif

#define lua_getfieldx(L, idx, k)	(lua_getfield(L, idx, k), lua_type(L, -1))

LUALIB_API int
lua_getix(lua_State *L, int i)
{
	lua_pushinteger(L, i);
	lua_gettable(L, -2);
	return lua_type(L, -1);
}

#else	// >= lua5.3

#define lua_getfieldx			lua_getfield
#define lua_getix(L, i)			lua_geti(L, -1, i)

#endif

static int
loadstring(lua_State *L, int frompath)
{
	int err;
	size_t sz;
	struct zproto_parser parser;
	const char *str = luaL_checklstring(L, 1, &sz);
	if (frompath) {
		err = zproto_load(&parser, str);
	} else {
		char *buff = (char *)malloc(sz + 1);
		memcpy(buff, str, sz);
		buff[sz] = 0;
		err = zproto_parse(&parser, buff);
		free(buff);
	}
	if (err < 0) {
		lua_pushnil(L);
		lua_pushstring(L, parser.error);
	} else {
		lua_pushlightuserdata(L, parser.z);
		lua_pushnil(L);
	}
	return 2;
}

static int
lload(lua_State *L)
{
	return loadstring(L, 1);
}

static int
lparse(lua_State *L)
{
	return loadstring(L, 0);
}

static struct zproto *
zproto(lua_State *L)
{
	struct zproto *z = (struct zproto *)lua_touserdata(L, 1);
	return z;
}

static int
lfree(lua_State *L)
{
	struct zproto *z = zproto(L);
	assert(z);
	zproto_free(z);
	return 0;
}

static int
lquery(lua_State *L)
{
	struct zproto_struct *r = NULL;
	struct zproto *z = zproto(L);
	int type = lua_type(L, 2);
	if (type == LUA_TNUMBER) {
		int tag = lua_tointeger(L, 2);
		r = zproto_querytag(z, tag);
	} else if (type == LUA_TSTRING) {
		const char *name = lua_tostring(L, 2);
		r = zproto_query(z, name);
	} else {
		luaL_error(L, "integer/string expected got:%d\n", type);
	}
	if (r == NULL) {
		lua_pushnil(L);
		lua_pushnil(L);
	} else {
		lua_pushlightuserdata(L, r);
		lua_pushinteger(L, zproto_tag(r));
	}
	return 2;
}

struct lencode_ud {
	int level;
	lua_State *L;
};

#define int8(ptr)   (*(int8_t *)ptr)
#define int16(ptr)   (*(int16_t *)ptr)
#define int32(ptr)   (*(int32_t *)ptr)
#define int64(ptr)   (*(int64_t *)ptr)
#define uint8(ptr)   (*(uint8_t *)ptr)
#define uint16(ptr)   (*(uint16_t *)ptr)
#define uint32(ptr)   (*(uint32_t *)ptr)
#define uint64(ptr)   (*(uint64_t *)ptr)
#define float32(ptr)  (*(float *)ptr)

#define CHECK_OOM(sz, need) \
	if (sz < (int)(need))\
		return ZPROTO_OOM;

#define checktype(expect)	checktype_(L, name, lua_type(L, -1), expect)

#define ENCODE_INTEGER(type)\
	checktype(LUA_TNUMBER);\
	d = luaL_checkinteger(L, -1);\
	type(args->buff) = (type##_t)d;\
	return sizeof(type##_t);

static int
checktype_(lua_State *L, const char *name, int type, int expect)
{
	if (type != expect) {
		const char *t = lua_typename(L, type);
		const char *e = lua_typename(L, expect);
		return luaL_error(L, "'%s':%s expected got %s\n", name, e, t);
	}
	return 0;
}


static int encode_table(struct zproto_args *args);

static int
encode_field(struct zproto_args *args)
{
	lua_Integer d;
	struct lencode_ud *eud = args->ud;
	lua_State *L = eud->L;
	const char *name = args->name;
	switch(args->type) {
	case ZPROTO_BOOLEAN: {
		checktype(LUA_TBOOLEAN);
		uint8_t d = lua_toboolean(L, -1);
		uint8(args->buff) = d;
		return sizeof(uint8_t);
	}
	case ZPROTO_BYTE:
		ENCODE_INTEGER(int8);
	case ZPROTO_SHORT:
		ENCODE_INTEGER(int16);
	case ZPROTO_INTEGER:
		ENCODE_INTEGER(int32);
	case ZPROTO_LONG:
		ENCODE_INTEGER(int64);
	case ZPROTO_UBYTE:
		ENCODE_INTEGER(uint8);
	case ZPROTO_USHORT:
		ENCODE_INTEGER(uint16);
	case ZPROTO_UINTEGER:
		ENCODE_INTEGER(uint32);
	case ZPROTO_ULONG:
		ENCODE_INTEGER(uint64);
	case ZPROTO_FLOAT: {
		checktype(LUA_TNUMBER);
		lua_Number d = luaL_checknumber(L, -1);
		float32(args->buff) = (float)d;
		return sizeof(float);
	}
	case ZPROTO_BLOB:
	case ZPROTO_STRING: {
		size_t sz;
		const char *d;
		checktype(LUA_TSTRING);
		d = luaL_checklstring(L, -1, &sz);
		CHECK_OOM(args->buffsz, sz);
		memcpy(args->buff, d, sz);
		return sz;
	}
	case ZPROTO_STRUCT: {
		struct lencode_ud ud;
		checktype(LUA_TTABLE);
		ud.level = eud->level + 1;
		ud.L = eud->L;
		return zproto_encode(args->sttype, args->buff, args->buffsz, encode_table, &ud);
	}
	}
	return ZPROTO_ERROR;
}

static int
encode_array(struct zproto_args *args)
{
	int n;
	int sz;
	struct lencode_ud *eud = args->ud;
	lua_State *L = eud->L;
	if (args->idx == 0) {
		int type;
		type = lua_getfieldx(L, -1, args->name);
		if (type == LUA_TNIL) {
			lua_pop(L, 1);
			return ZPROTO_NOFIELD;
		}
		checktype_(L, args->name, type, LUA_TTABLE);
		if (args->maptag)
			lua_pushnil(L);
	}
	if (args->maptag) {
		n = lua_next(L, -2);
		if (n == 0) {
			args->len = args->idx;
			lua_pop(L, 1);
			return ZPROTO_NOFIELD;
		}
	} else {
		int type;
		type = lua_getix(L, args->idx + 1);
		if (type == LUA_TNIL) {
			args->len = args->idx;
			lua_pop(L, 2);
			return ZPROTO_NOFIELD;
		}
	}
	sz = encode_field(args);
	lua_pop(L, 1);
	return sz;
}


static int
encode_table(struct zproto_args *args)
{
	int sz;
	struct lencode_ud *eud = args->ud;
	lua_State *L = eud->L;
	if (eud->level >= MAX_RECURSIVE) {
		const char *fmt = "encode_table too deep:%d stkidx:%d \n";
		return luaL_error(L, fmt, eud->level, lua_gettop(L));
	}
	if (args->idx >= 0) {
		sz = encode_array(args);
	} else {
		int type = lua_getfieldx(L, -1, args->name);
		if (type == LUA_TNIL) {
			lua_pop(L, 1);
			return ZPROTO_NOFIELD;
		}
		sz = encode_field(args);
		lua_pop(L, 1);
	}
	return sz;
}

static __inline void *
funcbuffer(lua_State *L, size_t *sz)
{
	*sz = lua_rawlen(L, lua_upvalueindex(1));
	return lua_touserdata(L, lua_upvalueindex(1));
}

static __inline void *
resizebuffer(lua_State *L, size_t sz)
{
	void *data = lua_newuserdatauv(L, sz, 0);
	lua_replace(L, lua_upvalueindex(1));
	return data;
}

static int
lencode(lua_State *L)
{
	uint8_t *data;
	size_t datasz;
	int sz, top, raw = 0;
	struct zproto_struct *st;
	struct lencode_ud ud;
	st = (struct zproto_struct *)lua_touserdata(L, 1);
	if (st == NULL)
		return luaL_error(L, "encode: 'struct' is null");
	top = lua_gettop(L);
	if (top >= 3) {
		raw = lua_toboolean(L, 3);
		lua_pop(L, 1);
		--top;
	}
	lua_checkstack(L, MAX_RECURSIVE * 3 + 8);
	ud.level = 0;
	ud.L = L;
	data = funcbuffer(L, &datasz);
	for (;;) {
		sz = zproto_encode(st, data, datasz, encode_table, &ud);
		if (sz == ZPROTO_OOM) {
			lua_settop(L, top);
			datasz *= 2;
			data = resizebuffer(L, datasz);
			continue;
		}
		break;
	}
	lua_settop(L, top);
	if (sz <= 0) {
		return 0;
	}else if(raw == 1) {
		lua_pushlightuserdata(L, data);
		lua_pushinteger(L, sz);
		return 2;
	} else {
		lua_pushlstring(L, (char *)data, sz);
		return 1;
	}
}

struct ldecode_ud {
	int level;
	lua_State *L;
	int duptag;
	int dupidx;
};

static int decode_table(struct zproto_args *args);

static int
decode_field(struct zproto_args *args)
{
	lua_State *L;
	struct ldecode_ud ud;
	struct ldecode_ud *now;
	now = args->ud;
	L = now->L;
	switch(args->type) {
	case ZPROTO_BOOLEAN:
		lua_pushboolean(L, uint8(args->buff));
		return sizeof(uint8_t);
	case ZPROTO_BYTE:
		lua_pushinteger(L, int8(args->buff));
		return sizeof(int8_t);
	case ZPROTO_SHORT:
		lua_pushinteger(L, int16(args->buff));
		return sizeof(int16_t);
	case ZPROTO_INTEGER:
		lua_pushinteger(L, int32(args->buff));
		return sizeof(int32_t);
	case ZPROTO_LONG:
		lua_pushinteger(L, int64(args->buff));
		return sizeof(int64_t);
	case ZPROTO_UBYTE:
		lua_pushinteger(L, uint8(args->buff));
		return sizeof(uint8_t);
	case ZPROTO_USHORT:
		lua_pushinteger(L, uint16(args->buff));
		return sizeof(uint16_t);
	case ZPROTO_UINTEGER:
		lua_pushinteger(L, uint32(args->buff));
		return sizeof(uint32_t);
	case ZPROTO_ULONG:
		lua_pushinteger(L, int64(args->buff));
		return sizeof(uint64_t);
	case ZPROTO_FLOAT:
		lua_pushnumber(L, float32(args->buff));
		return sizeof(uint32_t);
	case ZPROTO_BLOB:
	case ZPROTO_STRING:
		lua_pushlstring(L, (char *)args->buff, args->buffsz);
		return args->buffsz;
	case ZPROTO_STRUCT:
		ud.L = L;
		ud.level = now->level + 1;
		if (args->maptag) {
			int dupidx;
			lua_pushnil(L);
			dupidx = lua_gettop(L);
			assert(args->idx >= 0);
			ud.duptag = args->maptag;
			ud.dupidx = dupidx;
		} else {
			ud.duptag = 0;
			ud.dupidx = 0;
		}
		lua_newtable(L);
		return zproto_decode(args->sttype, args->buff, args->buffsz, decode_table, &ud);
	}
	return ZPROTO_ERROR;
}

static int
decode_array(struct zproto_args *args)
{
	int sz;
	lua_State *L;
	struct ldecode_ud *now = args->ud;
	L = now->L;
	if (args->idx == 0)
		lua_newtable(L);
	if (args->len == 0)	//empty array
		return 0;
	//array can't be mapkey
	assert(args->tag != now->duptag);
	if (args->maptag) {	//map
		assert(args->type == ZPROTO_STRUCT);
		sz = decode_field(args);
		if (sz < 0)
			return sz;
		lua_settable(L, -3);
	} else {
		sz = decode_field(args);
		if (sz < 0)
			return sz;
		//zproto array index start with 0
		lua_rawseti(L, -2, args->idx + 1);
	}
	return sz;
}

static int
decode_table(struct zproto_args *args)
{
	int sz;
	struct ldecode_ud *ud = args->ud;
	lua_State *L = ud->L;
	if (ud->level >= MAX_RECURSIVE) {
		const char *fmt = "decode_table too deep:%d stkidx:%d \n";
		fprintf(stderr, fmt, ud->level, lua_gettop(L));
		return ZPROTO_ERROR;
	}
	if (args->idx >= 0) {
		sz = decode_array(args);
	} else {
		sz = decode_field(args);
		if (ud->duptag == args->tag) {
			assert(ud->duptag > 0);
			assert(ud->dupidx > 0);
			assert(args->type != ZPROTO_STRUCT);
			lua_pushvalue(L, -1);
			lua_replace(L, ud->dupidx);
		}
	}
	if (sz < 0)
		return sz;
	if (args->idx + 1 >= args->len)
		lua_setfield(L, -2, args->name);
	return sz;
}

static inline const void *
get_buffer(lua_State *L, int *stk, size_t *sz)
{
	const char *ptr;
	int n = *stk;
	if (lua_type(L, n) == LUA_TSTRING) {
		ptr = luaL_checklstring(L, n, sz);
		++n;
	} else {
		ptr = (char *)lua_touserdata(L, n);
		*sz = luaL_checkinteger(L, n + 1);
		n = n + 2;
	}
	*stk = n;
	return ptr;
}

static int
ldecode(lua_State *L)
{
	size_t datasz;
	const uint8_t *data;
	int err, top, stk = 2;
	struct ldecode_ud ud;
	struct zproto_struct *st = lua_touserdata(L, 1);
	if (st == NULL)
		return luaL_error(L, "decode: 'struct' is null");
	lua_checkstack(L, MAX_RECURSIVE * 3 + 8);
	data = (uint8_t *)get_buffer(L, &stk, &datasz);
	lua_newtable(L);
	top = lua_gettop(L);
	ud.L = L;
	ud.level = 1;
	ud.duptag = 0;
	ud.dupidx = 0;
	err = zproto_decode(st, data, datasz, decode_table, &ud);
	lua_settop(L, top);
	if (err < 0) {
		lua_pop(L, 1);
		lua_pushnil(L);
	}
	lua_pushinteger(L, err);
	return 2;
}

static int default_table(struct zproto_args *args);

static int
default_field(struct zproto_args *args)
{
	struct lencode_ud *eud = args->ud;
	lua_State *L = eud->L;
	switch(args->type) {
	case ZPROTO_BOOLEAN: {
		lua_pushboolean(L, 0);
		break;
	}
	case ZPROTO_BYTE:
	case ZPROTO_SHORT:
	case ZPROTO_INTEGER:
	case ZPROTO_LONG:
	case ZPROTO_UBYTE:
	case ZPROTO_USHORT:
	case ZPROTO_UINTEGER:
	case ZPROTO_ULONG:
		lua_pushinteger(L, 0);
		break;
	case ZPROTO_FLOAT:
		lua_pushnumber(L, 0.0f);
		break;
	case ZPROTO_BLOB:
	case ZPROTO_STRING: {
		lua_pushliteral(L, "");
		break;
	}
	case ZPROTO_STRUCT: {
		int sz;
		//size, tagcount, arrlen, type size, tag space
		uint8_t buf[4+2+4+8+64*2];
		struct lencode_ud ud;
		lua_newtable(L);
		ud.level = eud->level + 1;
		ud.L = eud->L;
		sz = zproto_encode(args->sttype, buf,
			sizeof(buf), default_table, &ud);
		if (sz < 0)
			return sz;
		break;
	}}
	return 0;
}

static int
default_table(struct zproto_args *args)
{
	int err;
	struct lencode_ud *eud = args->ud;
	lua_State *L = eud->L;
	if (eud->level >= MAX_RECURSIVE) {
		const char *fmt = "default_table too deep:%d stkidx:%d \n";
		return luaL_error(L, fmt, eud->level, lua_gettop(L));
	}
	if (args->idx >= 0)
		lua_newtable(L);
	else if ((err = default_field(args)) < 0)
		return err;
	lua_setfield(L, -2, args->name);
	args->len = -1;
	return ZPROTO_NOFIELD;
}

static int
ldefault(lua_State *L)
{
	int top, sz;
	//assume max field count less then 64
	uint8_t buf[4+2+4+8+64*2];//size, tagcount, arrlen, type size, tag space
	struct lencode_ud ud;
	struct zproto_struct *st;
	st = (struct zproto_struct *)lua_touserdata(L, 1);
	if (st == NULL)
		return luaL_error(L, "encode: 'struct' is null");
	top = lua_gettop(L);
	ud.level = 0;
	ud.L = L;
	lua_newtable(L);
	sz = zproto_encode(st, buf, sizeof(buf), default_table, &ud);
	if (sz < 0) {
		lua_settop(L, top);
		return 0;
	}
	assert(lua_gettop(L) == (top + 1));
	return 1;
}


static int
ltravel_struct(lua_State *L)
{
	const struct zproto_starray *sts;
	lua_Integer i = luaL_checkinteger(L, 2);
	sts = (struct zproto_starray *)lua_touserdata(L, 1);
	if (sts != NULL && i < sts->count) {
		struct zproto_struct *st = sts->buf[i];
		i = luaL_intop(+, i, 1);
		lua_pushinteger(L, i);
		lua_pushstring(L, zproto_name(st));
		lua_pushlightuserdata(L, st);
	} else {
		lua_pushnil(L);
		lua_pushnil(L);
		lua_pushnil(L);
	}
	return 3;
}

static int
ltravel_field(lua_State *L)
{
	const struct zproto_struct *st;
	lua_Integer i = luaL_checkinteger(L, 2);
	st = (struct zproto_struct *)lua_touserdata(L, 1);
	if (i < st->fieldcount) {
		struct zproto_field *f = st->fields[i];
		i = luaL_intop(+, i, 1);
		lua_pushinteger(L, i);
		lua_newtable(L);
		lua_pushstring(L, f->name);
		lua_setfield(L, -2, "name");
		lua_pushinteger(L, f->tag);
		lua_setfield(L, -2, "tag");
		if (f->seminfo != NULL) {
			lua_pushstring(L, zproto_name(f->seminfo));
		} else {
			lua_pushstring(L, zproto_typename(f->type));
		}
		lua_setfield(L, -2, "type");
		lua_pushboolean(L, f->isarray);
		lua_setfield(L, -2, "array");
		if (f->mapkey != NULL) {
			lua_pushstring(L, f->mapkey->name);
			lua_setfield(L, -2, "mapkey");
		}
	} else {
		lua_pushnil(L);
		lua_pushnil(L);
	}
	return 2;

}

static int
ltravel(lua_State *L)
{
	size_t n;
	const char *mod;
	struct zproto *z;
	struct zproto_struct *st;
	z = zproto(L);
	mod = luaL_optlstring(L, 2, "field", &n);
	if (strcmp(mod, "struct") == 0) {
		const struct zproto_starray *sts;
		st = (struct zproto_struct *)lua_touserdata(L, 3);
		sts = (st == NULL) ? zproto_root(z) : st->child;
		lua_pushcfunction(L, ltravel_struct);
		lua_pushlightuserdata(L, (void *)sts);
		lua_pushinteger(L, 0);
	} else if (strcmp(mod, "field") == 0) {
		st = (struct zproto_struct *)lua_touserdata(L, 3);
		if (st == NULL) {
			return luaL_error(L, "travel field: 'struct' is null");
		}
		lua_pushcfunction(L, ltravel_field);
		lua_pushlightuserdata(L, (void *)st);
		lua_pushinteger(L, 0);
	} else {
		return luaL_error(L, "travel: 'mod' can only be [struct|field]");
	}
	return 3;
}


static int
lpack(lua_State *L)
{
	uint8_t *dst;
	int sz, raw, stk = 1;
	size_t	srcsz, dstsz;
	const uint8_t *src;
	src = get_buffer(L, &stk, &srcsz);
	raw = lua_toboolean(L, stk);
	dst = funcbuffer(L, &dstsz);
	for (;;) {
		sz = zproto_pack(src, srcsz, dst, dstsz);
		if (sz < 0) {
			assert(sz == ZPROTO_OOM);
			dstsz *= 2;
			dst = resizebuffer(L, dstsz);
			continue;
		}
		break;
	}
	assert(sz > 0);
	if (raw == 1) {
		lua_pushlightuserdata(L, dst);
		lua_pushinteger(L, sz);
		return 2;
	} else {
		lua_pushlstring(L, (char *)dst, sz);
		return 1;
	}
}

static int
lunpack(lua_State *L)
{
	uint8_t *dst;
	int sz, raw, stk = 1;
	size_t srcsz, dstsz;
	const uint8_t *src;
	src = get_buffer(L, &stk, &srcsz);
	raw = lua_toboolean(L, stk);
	dst = funcbuffer(L, &dstsz);
	for (;;) {
		sz = zproto_unpack(src, srcsz, dst, dstsz);
		if (sz == ZPROTO_OOM) {
			dstsz *= 2;
			dst = resizebuffer(L, dstsz);
			continue;
		}
		break;
	}
	if (sz < 0) {
		return 0;
	} else if (raw == 1) {
		lua_pushlightuserdata(L, dst);
		lua_pushinteger(L, sz);
		return 2;
	} else {
		lua_pushlstring(L, (char *)dst, sz);
		return 1;
	}
}

#define BUFFSIZE (128)

static void
setfuncs_withbuffer(lua_State *L, luaL_Reg tbl[])
{
	int i = 0;
	while (tbl[i].name) {
		lua_newuserdatauv(L, BUFFSIZE, 0);
		lua_pushcclosure(L, tbl[i].func, 1);
		lua_setfield(L, -2, tbl[i].name);
		i++;
	}
}

LUALIB_API int
luaopen_zproto_c(lua_State *L)
{
	luaL_Reg tbl1[] = {
		{"load", lload},
		{"parse", lparse},
		{"free", lfree},
		{"query", lquery},
		{"decode", ldecode},
		{"default", ldefault},
		{"travel", ltravel},
		{NULL, NULL},
	};

	luaL_Reg tbl2[] = {
		//encode/decode
		{"encode", lencode},
		{"pack", lpack},
		{"unpack", lunpack},
		{NULL, NULL},
	};

	luaL_checkversion(L);
	luaL_newlib(L, tbl1);
	setfuncs_withbuffer(L, tbl2);
	return 1;
}

