#include <assert.h>
#include <stdlib.h>
#include <stdio.h>
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>

#include "silly_message.h"
#include "silly_worker.h"
#include "silly_socket.h"
#include "silly_malloc.h"

static void
_process_socket(lua_State *L, void *m)
{
        int err;
        struct silly_message_socket *msg;

        msg = (struct silly_message_socket *)m;
        
        lua_pushlightuserdata(L, _process_socket);
        lua_gettable(L, LUA_REGISTRYINDEX);

        lua_pushlightuserdata(L, msg);
        luaL_getmetatable(L, "silly_message_socket");
        lua_setmetatable(L, -2);

        err = lua_pcall(L, 1, 0, 0);
        if (err != 0)
                fprintf(stderr, "_process_socket call failed:%s\n", lua_tostring(L, -1));
        
        return ;
}

/*
static void
_process_timer(lua_State *L, void *m)
{
        //struct silly_message_timer *msg = (struct silly_message_timer *)m;
}
*/

static int
_socket_recv(lua_State *L)
{
        struct silly_worker *w;
        w = lua_touserdata(L, lua_upvalueindex(1));
        silly_worker_register(w, SILLY_MESSAGE_SOCKET, _process_socket);

        lua_pushlightuserdata(L, _process_socket);
        lua_insert(L, -2);
        lua_settable(L, LUA_REGISTRYINDEX);

        return 0;
}

static int
_socket_send(lua_State *L)
{
        int sid;
        char *buff;
        int size;
 
        sid = luaL_checkinteger(L, 1);
        buff = luaL_checkudata(L, 2, "silly_message_socket");
        size = luaL_checkinteger(L, 3);

        silly_socket_send(sid, buff, size);


        return 0;
}

int luaopen_server(lua_State *L)
{
        luaL_Reg tbl[] = {
                {"recv", _socket_recv},
                {"send", _socket_send},
                {NULL, NULL},
        };
 
        luaL_checkversion(L);

        luaL_newmetatable(L, "silly_message_socket");
        luaL_newmetatable(L, "silly_message_timer");
        luaL_newmetatable(L, "silly_socket_packet");

        lua_rawgeti(L, LUA_REGISTRYINDEX, LUA_RIDX_MAINTHREAD);
        lua_State *m = lua_tothread(L, -1);
        lua_pop(L, 1);

        lua_pushlightuserdata(L, (void *)m);
        lua_gettable(L, LUA_REGISTRYINDEX);
        struct silly_worker *w = lua_touserdata(L, -1);
        assert(w);


        luaL_newlibtable(L, tbl);
        lua_pushlightuserdata(L, (void *)w);
        luaL_setfuncs(L, tbl, 1);
        

        return 1;
}
