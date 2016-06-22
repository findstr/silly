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
        struct zproto_record *r = NULL;
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

static int encode_table(lua_State *L, struct zproto_buffer *zb, struct zproto_record *proto, int deep);

static int
encode_data(lua_State *L, struct zproto_buffer *zb, struct zproto_field_iter *iter, int deep)
{
        int err = 0;
        int type = zproto_field_type(iter->p);
        const char *name = zproto_field_name(iter->p);
        switch (type & ZPROTO_TYPE) {
        case ZPROTO_BOOLEAN: {
                if (lua_type(L, -1) != LUA_TBOOLEAN) {
                        fprintf(stderr, "encode data:need boolean field:%s\n", name);
                        return -1;
                }
                int8_t d = lua_toboolean(L, -1);
                zproto_encode(zb, iter, (char *)&d, sizeof(d));
                break;
        }
        case ZPROTO_INTEGER: {
                if (lua_type(L, -1) != LUA_TNUMBER) {
                        fprintf(stderr, "encode_data:need integer field:%s\n", name);
                        return -1;
                }
                int32_t d = luaL_checkinteger(L, -1);
                zproto_encode(zb, iter, (char *)&d, sizeof(d));
                break;
        }
        case ZPROTO_STRING: {
                if (lua_type(L, -1) != LUA_TSTRING) {
                        fprintf(stderr, "encode_data:need string field:%s\n", name);
                        return -1;
                }
                size_t sz;
                const char *d = luaL_checklstring(L, -1, &sz);
                zproto_encode(zb, iter, d, sz);
                break;
        }
        case ZPROTO_RECORD: {
                struct zproto_record *seminfo = zproto_field_seminfo(iter->p);
                if (lua_type(L, -1) != LUA_TTABLE) {
                        fprintf(stderr, "encode_data:need table field:%s\n", name);
                        return -1;
                }
                zproto_encode(zb, iter, NULL, 0);
                err = encode_table(L, zb, seminfo, deep + 1);
                break;
        }
        default:
                fprintf(stderr, "encode_data, unkonw field type:%d\n", type);
                err = -1;
        }
        
        return err;
}

static int
encode_array(lua_State *L, struct zproto_buffer *zb, struct zproto_field_iter *iter, int deep)
{
        int i;
        int err;
        int acount = lua_rawlen(L, -1);
        zproto_encode_array(zb, iter, acount);
        for (i = 1; i <= acount; i++) {
                lua_rawgeti(L, -1, i);
                err = encode_data(L, zb, iter, deep);
                lua_pop(L, 1);
                if (err < 0)
                        return err;
        }

        return 0;
}

static int
encode_table(lua_State *L, struct zproto_buffer *zb, struct zproto_record *proto, int deep)
{
        int err;
        int nr = 0;
        struct zproto_field_iter iter;
        int32_t field_nr = zproto_encode_record(zb);
        
        if (deep >= MAX_RECURSIVE)
                return -1;

        for (zproto_field_begin(proto, &iter); !zproto_field_end(&iter); zproto_field_next(&iter)) {
                lua_getfield(L, -1, zproto_field_name(iter.p));
                if (lua_type(L, -1) == LUA_TNIL) {
                        lua_pop(L, 1);
                        continue;
                }

                if (zproto_field_type(iter.p) & ZPROTO_ARRAY) {
                        err = encode_array(L, zb, &iter, deep);
                        if (err < 0)
                                return err;
                } else {
                        err = encode_data(L, zb, &iter, deep);
                        if (err < 0)
                                return err;
                }
                lua_pop(L, 1);
                ++nr;
        }

        zproto_encode_recordnr(zb, field_nr, nr);
        return 0;
}

static int
lencode(lua_State *L)
{
        int err;
        int sz;
        const uint8_t *data;
        struct zproto *z = zproto(L);
        struct zproto_record *proto = (struct zproto_record *)lua_touserdata(L, 2);
        lua_checkstack(L, MAX_RECURSIVE * 2 + 8);
        struct zproto_buffer *zb = zproto_encode_begin(z);
        err = encode_table(L, zb, proto, 0);
        if (err < 0) {
                data = NULL;
        } else {
                data = zproto_encode_end(zb, &sz);
        }
        if (data) {
                lua_pushlstring(L, (char *)data, sz);
        } else {
                lua_pushnil(L);
        }
        return 1;
}
static int decode_table(lua_State *L, struct zproto_record *proto, struct zproto_buffer *zb, int deep);

static int
decode_data(lua_State *L, struct zproto_field_iter *iter, struct  zproto_buffer *zb, int deep)
{
        int err;
        int type = zproto_field_type(iter->p);
        switch (type & ZPROTO_TYPE) {
        case ZPROTO_BOOLEAN: {
                uint8_t *b;
                int32_t sz;
                err = zproto_decode(zb, iter, &b, &sz);
                if (err < 0)
                        return err;
                assert(sz == 1);
                lua_pushboolean(L, *b);
                break;
        }
        case ZPROTO_STRING: {
                uint8_t *str;
                int32_t sz;
                err = zproto_decode(zb, iter, &str, &sz);
                if (err < 0)
                        return err;
                lua_pushlstring(L, (char *)str, sz);
                break;
        }
        case ZPROTO_INTEGER: {
                int32_t *d;
                int32_t sz;
                err = zproto_decode(zb, iter, (uint8_t **)&d, &sz);
                if (err < 0)
                        return err;
                assert(sz == sizeof(int32_t));
                lua_pushinteger(L, *d);
                break;
        }
        case ZPROTO_RECORD: {
                lua_newtable(L);
                err = decode_table(L, zproto_field_seminfo(iter->p), zb, deep + 1);
                if (err < 0)
                        return err;
                break;
        }
        default:
                fprintf(stderr, "invalid field type:%d\n", type);
                return -1;
        }

        return 0;
}

static int
decode_array(lua_State *L, struct zproto_field_iter *iter, struct zproto_buffer *zb, int count, int deep)
{
        int i;
        int err;
        lua_newtable(L);
        for (i = 1; i <= count; i++) {
                err = decode_data(L, iter, zb, deep);
                if (err < 0)
                        return err;
                lua_rawseti(L, -2, i);
        }

        return 0;
}

static int
decode_table(lua_State *L, struct zproto_record *proto, struct zproto_buffer *zb, int deep)
{
        int i;
        int sz;
        int err;
        struct zproto_field_iter iter;

        if (deep >= MAX_RECURSIVE)
                return -1;

        int field_nr = zproto_decode_record(zb, &iter);
        for (i = 0; i < field_nr; i++) {
                err = zproto_decode_field(zb, proto, &iter, &sz);
                if (err < 0)
                        return err;
                if (zproto_field_type(iter.p) & ZPROTO_ARRAY)
                        err = decode_array(L, &iter, zb, sz, deep);
                else
                        err = decode_data(L, &iter, zb, deep);
                if (err < 0)
                        return err;
                lua_setfield(L, -2, zproto_field_name(iter.p));
        }

        return 0;
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
        uint8_t *ud;
        size_t sz;
        struct zproto *z = zproto(L);
        struct zproto_record *proto = lua_touserdata(L, 2);
        lua_checkstack(L, MAX_RECURSIVE * 2 + 8);
        ud = (uint8_t *)get_buffer(L, 3, &sz);
        struct zproto_buffer *zb = zproto_decode_begin(z, ud, sz);
        lua_newtable(L);
        err = decode_table(L, proto, zb, 0);
        sz = zproto_decode_end(zb);
        if (err < 0) {
                lua_settop(L, 1);
                lua_pushnil(L);
        }
        lua_pushinteger(L, sz);
        return 2;
}

static int
ltostring(lua_State *L)
{
        const uint8_t *ud = (uint8_t *)lua_touserdata(L, 2);
        size_t sz = luaL_checkinteger(L, 3);
        lua_pushlstring(L, (const char *)ud, sz);

        return 1;
}

static int
lpack(lua_State *L)
{
        int osz;
        size_t sz;
        const uint8_t *ud;
        const uint8_t *pack;
        ud = get_buffer(L, 2, &sz);
        pack = zproto_pack(zproto(L), ud, sz, &osz);
        if (pack)
                lua_pushlstring(L, (char *)pack, osz);
        else
                lua_pushnil(L);

        return 1;
}

static int
lunpack(lua_State *L)
{
        size_t sz;
        int osz;
        const uint8_t *ud;
        const uint8_t *unpack;
        ud = get_buffer(L, 2, &sz);
        unpack = zproto_unpack(zproto(L), ud, sz, &osz);
        if (unpack) {
                lua_pushlstring(L, (char *)unpack, osz);
        } else {
                lua_pushnil(L);
        }
        return 1;
}

int
luaopen_zproto_c(lua_State *L)
{
        luaL_Reg tbl[] = {
                {"load", lload},
                {"parse", lparse},
                {"free", lfree},
                {"query", lquery},
                //encode/decode
                {"encode", lencode},
                {"decode", ldecode},
                //pack/unpack
                {"pack", lpack},
                {"unpack", lunpack},
                {"tostring", ltostring},
                {NULL, NULL},
        };

        luaL_checkversion(L);
        luaL_newlib(L, tbl);
        return 1;
}



