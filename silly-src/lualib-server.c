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
#include "silly_timer.h"

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

static void
_process_timer(lua_State *L, void *m)
{
        void *key;
        int type;
        int err;
        struct silly_message_timer *msg = (struct silly_message_timer *)m;

        key = (void *)msg->sig;
        
        lua_pushlightuserdata(L, key);
        lua_gettable(L, LUA_REGISTRYINDEX);
        type = lua_type(L, -1);
        if (type == LUA_TFUNCTION) {
                lua_pushlightuserdata(L, key);
                lua_pushnil(L);
                lua_settable(L, LUA_REGISTRYINDEX);

                err = lua_pcall(L, 0, 0, 0);
                if (err != 0)
                        fprintf(stderr, "timer handler call fail:%s\n", lua_tostring(L, -1));

        } else if (type != LUA_TNIL) {
                fprintf(stderr, "_process_timer invalid type:%d\n", type);
        } else {
                fprintf(stderr, "_process_timer2 invalid type:%d\n", type);
        }

        return ;
}


static int
_timer_add(lua_State *L)
{
        int err;
        int workid;
        int time;
        struct silly_worker *w;
        w = lua_touserdata(L, lua_upvalueindex(1));
 
        time = luaL_checkinteger(L, 1);

        if (lua_type(L, 2) != LUA_TFUNCTION) {
                fprintf(stderr, "timer handler need a lua function\n");
                return 0;
        }

        uintptr_t key = (uintptr_t)lua_topointer(L, 2);
        lua_pushlightuserdata(L, (void *)key);
        lua_insert(L, -2);
        lua_settable(L, LUA_REGISTRYINDEX);
        
        workid = silly_worker_getid(w);

        err = timer_add(time, workid, key);

        lua_pushinteger(L, err);

        return 1;
}

int luaopen_server(lua_State *L)
{
        luaL_Reg tbl[] = {
                {"socket_recv", _socket_recv},
                {"socket_send", _socket_send},
                {"timer_add", _timer_add},
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

        silly_worker_register(w, SILLY_MESSAGE_TIMER, _process_timer);

        luaL_newlibtable(L, tbl);
        lua_pushlightuserdata(L, (void *)w);
        luaL_setfuncs(L, tbl, 1);
        

        return 1;
}
