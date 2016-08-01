#include <stdio.h>
#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "lua.h"
#include "lualib.h"
#include "lauxlib.h"
#include "zproto.h"

#define MAX_RECURSIVE   (64)

static int
loadstring(lua_State *L, int frompath)
{
        int err;
        size_t sz;
        const char *str = luaL_checklstring(L, 1, &sz);
        struct zproto *z = zproto_create();
        if (frompath) {
                err = zproto_load(z, str);
        } else {
                char *buff = (char *)malloc(sz + 1);
                memcpy(buff, str, sz);
                buff[sz] = 0;
                err = zproto_parse(z, buff);
                free(buff);
        }
        if (err < 0) {
                lua_pushnil(L);
                zproto_free(z);
        } else {
                lua_pushlightuserdata(L, z);
        }
        return 1;
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
        if (lua_type(L, 2) == LUA_TNUMBER) {
                int tag = luaL_checkinteger(L, 2);
                r = zproto_querytag(z, tag);
        } else if (lua_type(L, 2) == LUA_TSTRING) {
                const char *name = luaL_checkstring(L, 2);
                r = zproto_query(z, name);
        } else {
                luaL_error(L, "lquery expedted integer/string, but got:%d\n", lua_type(L, 2));
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

#define CHECK_OOM(sz, need) \
        if (sz < need)\
                return ZPROTO_OOM;

#define uint8(ptr)    (*(uint8_t *)ptr)
#define uint32(ptr)   (*(uint32_t *)ptr)

static int encode_table(struct zproto_args *args);

static int
encode_field(struct zproto_args *args)
{
        struct lencode_ud *eud = args->ud;
        lua_State *L = eud->L;
        const char *name = args->name;
        switch (args->type) {
        case ZPROTO_BOOLEAN: {
                if (lua_type(L, -1) != LUA_TBOOLEAN) {
                        fprintf(stderr, "encode data:need boolean field:%s\n", name);
                        return ZPROTO_ERROR;
                }
                CHECK_OOM(args->buffsz, sizeof(uint8_t))
                int8_t d = lua_toboolean(L, -1);
                uint8(args->buff) = d;
                return sizeof(uint8_t);
        }
        case ZPROTO_INTEGER: {
                if (lua_type(L, -1) != LUA_TNUMBER) {
                        fprintf(stderr, "encode_data:need integer field:%s\n", name);
                        return ZPROTO_ERROR;
                }
                CHECK_OOM(args->buffsz, sizeof(uint32_t))
                int32_t d = luaL_checkinteger(L, -1);
                uint32(args->buff) = (uint32_t)d;
                return sizeof(uint32_t);
        }
        case ZPROTO_STRING: {
                if (lua_type(L, -1) != LUA_TSTRING) {
                        fprintf(stderr, "encode_data:need string field:%s\n", name);
                        return ZPROTO_ERROR;
                }
                size_t sz;
                const char *d = luaL_checklstring(L, -1, &sz);
                CHECK_OOM(args->buffsz, sz)
                memcpy(args->buff, d, sz);
                return sz;
        }
        case ZPROTO_STRUCT: {
                if (lua_type(L, -1) != LUA_TTABLE) {
                        fprintf(stderr, "encode_data:need table field:%s\n", name);
                        return ZPROTO_ERROR;
                }
                struct lencode_ud ud;
                ud.level = eud->level + 1;
                ud.L = eud->L;
                return zproto_encode(args->sttype, args->buff, args->buffsz, encode_table, &ud);
        }
        default:
                fprintf(stderr, "encode_data, unkonw field type:%d\n", args->type);
                return ZPROTO_ERROR;
        }
}

static int
encode_array(struct zproto_args *args)
{
        int n;
        int sz;
        struct lencode_ud *eud = args->ud;
        lua_State *L = eud->L;
        if (args->idx == 0) {
                lua_getfield(L, -1, args->name);
                if (lua_type(L, -1) == LUA_TNIL) {
                        lua_pop(L, 1);
                        return ZPROTO_NOFIELD;
                }
                lua_pushnil(L);
        }
        n = lua_next(L, -2);
        if (n == 0) {
                args->len = args->idx;
                lua_pop(L, 1);
                return ZPROTO_NOFIELD;
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
                fprintf(stderr, fmt, eud->level, lua_gettop(L));
                return ZPROTO_ERROR;
        }
        if (args->idx >= 0) {
                sz = encode_array(args);
        } else {
                lua_getfield(L, -1, args->name);
                if (lua_type(L, -1) == LUA_TNIL) {
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
        void *data = lua_newuserdata(L, sz);
        lua_replace(L, lua_upvalueindex(1));
        return data;
}

static int
lencode(lua_State *L)
{
        int sz;
        int top;
        uint8_t *data;
        size_t datasz;
        struct zproto_struct *st;
        struct lencode_ud ud;
        st = (struct zproto_struct *)lua_touserdata(L, 1);
        lua_checkstack(L, MAX_RECURSIVE * 3 + 8);
        ud.level = 0;
        ud.L = L;
        data = funcbuffer(L, &datasz);
        top = lua_gettop(L);
        for (;;) {
                sz = zproto_encode(st, data, datasz, encode_table, &ud);
                if (sz == ZPROTO_OOM) {
                        lua_settop(L, top);
                        datasz *= 2;
                        data = resizebuffer(L, datasz);
                        continue;
                }
                assert(sz == ZPROTO_ERROR || sz > 0);
                break;
        }
        lua_settop(L, top);
        if (sz > 0) {
                lua_pushlstring(L, (char *)data, sz);
        } else {
                lua_pushnil(L);
        }
        return 1;
}

struct ldecode_ud {
        int level;
        lua_State *L;
        int duptag;
        int dupidx;
};

static int decode_table(struct zproto_args *args);

static int 
decode_field(struct zproto_args *args, int dupidx)
{
        int ret;
        lua_State *L;
        struct ldecode_ud ud;
        struct ldecode_ud *now = args->ud;
        L = now->L;
        switch (args->type) {
        case ZPROTO_BOOLEAN:
                lua_pushboolean(L, uint8(args->buff));
                ret = args->buffsz;
                break;
        case ZPROTO_STRING:
                lua_pushlstring(L, (char *)args->buff, args->buffsz);
                ret = args->buffsz;
                break;
        case ZPROTO_INTEGER:
                lua_pushinteger(L, uint32(args->buff));
                ret = args->buffsz;
                break;
        case ZPROTO_STRUCT:
                lua_newtable(L);
                ud.L = L;
                ud.level = now->level + 1;
                if (args->maptag) {
                        assert(args->idx >= 0);
                        assert(dupidx > 0);
                        ud.duptag = args->maptag;
                        ud.dupidx = dupidx;
                } else {
                        ud.duptag = 0;
                        ud.dupidx = 0;
                }
                ret = zproto_decode(args->sttype, args->buff, args->buffsz, decode_table, &ud);
                break;
        default:
                fprintf(stderr, "invalid field type:%d\n", args->type);
                return ZPROTO_ERROR;
        }

        if (now->duptag == args->tag) {
                assert(now->duptag > 0);
                assert(now->dupidx > 0);
                assert(args->type != ZPROTO_STRUCT);
                lua_pushvalue(L, -1);
                lua_replace(L, now->dupidx);
        }
        return ret;
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
        if (args->len == 0)     //empty array
                return 0;
        //array can't be mapkey
        assert(args->tag != now->duptag);
        if (args->maptag) {      //map
                assert(args->type == ZPROTO_STRUCT);
                lua_pushnil(L);
                sz = decode_field(args, lua_gettop(L));
                if (sz < 0)
                        return sz;
                lua_settable(L, -3);
        } else {
                sz = decode_field(args, 0);
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
        if (args->idx >= 0)
                sz = decode_array(args);
        else
                sz = decode_field(args, 0);
 
        if (sz < 0)
                return sz;
        if (args->idx + 1 >= args->len)
                lua_setfield(L, -2, args->name);
        return sz;
}

static const void *
get_buffer(lua_State *L, int n, size_t *sz)
{
        if (lua_type(L, n) == LUA_TSTRING) {
                return luaL_checklstring(L, n, sz);
        } else {
                *sz = luaL_checkinteger(L, n + 1);
                return lua_touserdata(L, n);
        }

        return NULL;
}

static int
ldecode(lua_State *L)
{
        int err;
        int top;
        struct ldecode_ud ud;
        size_t datasz;
        const uint8_t *data;
        struct zproto_struct *st = lua_touserdata(L, 1);

        lua_checkstack(L, MAX_RECURSIVE * 3 + 8);
        data = (uint8_t *)get_buffer(L, 2, &datasz);
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

static int
lpack(lua_State *L)
{
        int     sz;
        size_t  dstsz;
        size_t  srcsz;
        uint8_t *dst;
        const uint8_t *src;
        src = get_buffer(L, 1, &srcsz);
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
        lua_pushlstring(L, (char *)dst, sz);
        return 1;
}

static int
lunpack(lua_State *L)
{
        int sz;
        size_t dstsz;
        size_t srcsz;
        uint8_t *dst;
        const uint8_t *src;
        src = get_buffer(L, 1, &srcsz);
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
        if (sz < 0)
                lua_pushnil(L);
        else
                lua_pushlstring(L, (char *)dst, sz);
        return 1;
}

#define BUFFSIZE        (128)

static void 
setfuncs_withbuffer(lua_State *L, luaL_Reg tbl[])
{
        int i = 0;
        while (tbl[i].name) {
                lua_newuserdata(L, BUFFSIZE);
                lua_pushcclosure(L, tbl[i].func, 1);
                lua_setfield(L, -2, tbl[i].name);
                i++;
        }
}

int
luaopen_zproto_c(lua_State *L)
{
        luaL_Reg tbl1[] = {
                {"load", lload},
                {"parse", lparse},
                {"free", lfree},
                {"query", lquery},
                {"decode", ldecode},
                {NULL, NULL},
        };

        luaL_Reg tbl2[] = {
                //encode/decode
                {"encode", lencode},
                {"pack", lpack},
                {"unpack", lunpack},
                {NULL,  NULL},
        };

        luaL_checkversion(L);
        luaL_newlib(L, tbl1);
        setfuncs_withbuffer(L, tbl2);
        return 1;
}



