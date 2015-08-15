#include <assert.h>
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>
#include <stdlib.h>
#include <string.h>

#include "silly_malloc.h"
#include "silly_message.h"

#define LINE_CAPACITY  64

struct line_packet {
        int sid;
        int capacity;
        int end;
        char buff[LINE_CAPACITY];
};


static int
_create_linepacket(lua_State *L)
{
        struct line_packet *bp = lua_newuserdata(L, sizeof(struct line_packet));
        
        bp->capacity = LINE_CAPACITY;
        bp->end = 0;
        bp->sid = -1;

        luaL_getmetatable(L, "linepacket");
        lua_setmetatable(L, -2);

        return 1;
}

static struct line_packet *
_expand_buff(lua_State *L, int data_size)
{
        int need;
        struct line_packet *bp = luaL_checkudata(L, 1, "linepacket");
        struct line_packet *new;

        if (bp->capacity - bp->end > data_size)
                return bp;

        need = ((data_size + bp->end - bp->capacity +  LINE_CAPACITY - 1) / LINE_CAPACITY) * LINE_CAPACITY;
        new = (struct line_packet *)lua_newuserdata(L, sizeof(struct line_packet) - LINE_CAPACITY + bp->capacity + need);
        new->sid = bp->sid;
        new->capacity = bp->capacity + need;
        new->end = bp->end;
        memcpy(new->buff, bp->buff, bp->end);

        luaL_getmetatable(L, "linepacket");
        lua_setmetatable(L, -2);


        lua_replace(L, 1);

        return new;
}

static void
_push_rawdata(lua_State *L, int sid, uint8_t *data, int data_size)
{
        struct line_packet *p;

        p = _expand_buff(L, data_size);

        assert((p->sid == sid) || (p->sid == -1));
        p->sid = sid;

        memcpy(&p->buff[p->end], data, data_size);

        p->end += data_size;

        return ;
}

static int
_pop_linepacket(lua_State *L)
{
        int i;
        int line;
        struct line_packet *bp = luaL_checkudata(L, 1, "linepacket");

        for (i = 0; i < bp->end; i++) {
                if (bp->buff[i] == '\n') {
                        line = i;
                        break;
                }
        }

        if (i >= bp->end) {
                lua_pushnil(L);
                lua_pushnil(L);
        } else {
                ++line;
                lua_pushinteger(L, bp->sid);
                lua_pushlstring(L, bp->buff, line);
                bp->end -= line;
                memmove(bp->buff, &bp->buff[line], bp->end);
        }

        return 2;
}


static int
_push_linepacket(lua_State *L)
{
        int                     sid;
        uint8_t                 *data;
        int                     data_size;
        
        sid = luaL_checkinteger(L, 2);
        data = (uint8_t *)luaL_checkudata(L, 3, "silly_socket_data");
        data_size = luaL_checkinteger(L, 4);

        _push_rawdata(L, sid, data, data_size);

        lua_settop(L, 1);

        return 1;
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

int luaopen_linepacket(lua_State *L)
{
        luaL_Reg tbl[] = {
                {"create", _create_linepacket},
                {"push", _push_linepacket},
                {"pop", _pop_linepacket},
                {"pack", _pack_raw},
                {NULL, NULL},
        };
 
        luaL_checkversion(L);

        luaL_newmetatable(L, "linepacket");

        luaL_newlibtable(L, tbl);
        luaL_setfuncs(L, tbl, 0);
        
        return 1;
}
