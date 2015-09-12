#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <lua.h>
#include <lauxlib.h>

#include "silly_malloc.h"
#include "silly_message.h"

struct rawpacket {
        int     pushed;
        int     sid;
        int     len;
        char    *data;
};

static int
_create_rawpacket(lua_State *L)
{
        struct rawpacket *r = lua_newuserdata(L, sizeof(struct rawpacket));
        memset(r, 0, sizeof(*r));

        luaL_getmetatable(L, "rawpacket");
        lua_setmetatable(L, -2);

        return 1;
}

static int
_push_rawpacket(lua_State *L)
{
        int                     sid;
        char                    *data;
        int                     data_size;
        struct rawpacket        *r;

        r = (struct rawpacket *)luaL_checkudata(L, 1, "rawpacket");


        sid = luaL_checkinteger(L, 2);
        data = (char *)luaL_checkudata(L, 3, "silly_socket_data");
        data_size = luaL_checkinteger(L, 4);

        r->sid = sid;
        r->data = data;
        r->len = data_size;
        r->pushed = 1;

        lua_settop(L, 1);
        return 1;
}

static int
_pop_packet(lua_State *L)
{
        struct rawpacket *p;
        p = luaL_checkudata(L, 1, "rawpacket");
        assert(p);
        if (p->pushed == 0) {
                lua_pushnil(L);
                lua_pushnil(L);
        } else {
                lua_pushinteger(L, p->sid);
        
                //TODO:when implete the cryption module, will use the lua_pushlightuserdata funciton,
                //the lua_pushlstring function will be called by cryption module

                lua_pushlstring(L, p->data, p->len);
                p->pushed = 0;
        }

        return 2;
}

static int
_pack_raw(lua_State *L)
{
        const char *str;
        size_t size;
        char *p;

        str = luaL_checklstring(L, 1, &size);
        assert(size < (unsigned short)-1);

        p = silly_malloc(size);
        memcpy(p, str, size);

        lua_pushlightuserdata(L, p);
        luaL_getmetatable(L, "silly_socket_packet");
        lua_setmetatable(L, -2);
        lua_pushinteger(L, size);

        return 2;
}

int luaopen_rawpacket(lua_State *L)
{
        luaL_Reg tbl[] = {
                {"create", _create_rawpacket},
                {"push", _push_rawpacket},
                {"pop", _pop_packet},
                {"pack", _pack_raw},
                {NULL, NULL},
        };
 
        luaL_checkversion(L);

        luaL_newmetatable(L, "rawpacket");

        luaL_newlibtable(L, tbl);
        luaL_setfuncs(L, tbl, 0);
        
        return 1;
}
