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
_process_socket(lua_State *L, struct silly_message *m)
{
        int err;
        
        struct silly_message_socket *sm = (struct silly_message_socket *)(m + 1);

        lua_pushlightuserdata(L, _process_socket);
        lua_gettable(L, LUA_REGISTRYINDEX);

        lua_pushlightuserdata(L, m);
        luaL_getmetatable(L, "silly_message");
        lua_setmetatable(L, -2);

        err = lua_pcall(L, 1, 0, 0);
        if (err != 0)
                fprintf(stderr, "_process_socket call failed:%s\n", lua_tostring(L, -1));
        
        silly_free(sm->data);

        return ;
}

static int
_socket_connect(lua_State *L)
{
        const char *ip;
        int port;
        int err;
        int workid;
        struct silly_worker *w;
        
        w = lua_touserdata(L, lua_upvalueindex(1));
        workid = silly_worker_getid(w);


        ip = luaL_checkstring(L, 1);
        port = luaL_checkinteger(L, 2);

        err = silly_socket_connect(ip, port, workid);

        lua_pushinteger(L, err);

        return 1;
}


static int
_socket_close(lua_State *L)
{
        int err;
        int sid;

        sid = luaL_checkinteger(L, 1);

        err = silly_socket_close(sid);

        lua_pushinteger(L, err);

        return 1;
}

static int
_socket_shutdown(lua_State *L)
{
        int err;
        int sid;

        sid = luaL_checkinteger(L, 1);

        err = silly_socket_shutdown(sid);

        lua_pushinteger(L, err);

        return 1;
}


static int
_socket_recv(lua_State *L)
{
        lua_pushlightuserdata(L, _process_socket);
        lua_insert(L, -2);
        lua_settable(L, LUA_REGISTRYINDEX);

        return 0;
}

static int
_socket_send(lua_State *L)
{
        int sid;
        uint8_t *buff;
        int size;
 
        sid = luaL_checkinteger(L, 1);
        buff = luaL_checkudata(L, 2, "silly_socket_packet");
        size = luaL_checkinteger(L, 3);

        silly_socket_send(sid, buff, size);

        return 0;
}

static void
_process_timer(lua_State *L, struct silly_message *m)
{
        int type;
        int err;
        struct silly_message_timer *tm = (struct silly_message_timer *)(m + 1);

        lua_pushlightuserdata(L, _process_timer);
        lua_gettable(L, LUA_REGISTRYINDEX);
        type = lua_type(L, -1);
        if (type == LUA_TFUNCTION) {
                lua_pushinteger(L, tm->session);
                err = lua_pcall(L, 1, 0, 0);
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
_timer_register(lua_State *L)
{
        lua_pushlightuserdata(L, _process_timer); 
        lua_insert(L, -2);
        lua_settable(L, LUA_REGISTRYINDEX);

        return 0;
}

static int
_timer_add(lua_State *L)
{
        int err;
        int workid;
        int time;
        uint64_t session;
        struct silly_worker *w;
        w = lua_touserdata(L, lua_upvalueindex(1));
 
        time = luaL_checkinteger(L, 1);
        session = luaL_checkinteger(L, 2);

        workid = silly_worker_getid(w);

        err = timer_add(time, workid, session);

        lua_pushinteger(L, err);

        return 1;
}

static int
_get_workid(lua_State *L)
{
        int workid;
        struct silly_worker *w;
        w = lua_touserdata(L, lua_upvalueindex(1));
        workid = silly_worker_getid(w);

        lua_pushinteger(L, workid);

        return 1;

}

static void
_process_msg(lua_State *L, struct silly_message *msg)
{

        switch (msg->type) {
        case SILLY_TIMER_EXECUTE:
                //fprintf(stderr, "silly_worker:_process:%d\n", w->workid);
                _process_timer(L, msg);
                break;
        case SILLY_SOCKET_ACCEPT:
        case SILLY_SOCKET_CLOSE:
        case SILLY_SOCKET_CLOSED:
        case SILLY_SOCKET_SHUTDOWN:
        case SILLY_SOCKET_CONNECTED:
        case SILLY_SOCKET_DATA:
                //fprintf(stderr, "silly_worker:_process:socket\n");
                _process_socket(L, msg);
                break;
        default:
                fprintf(stderr, "silly_worker:_process:unknow message type:%d\n", msg->type);
                assert(0);
                break;
        }
}

int luaopen_silly(lua_State *L)
{
        luaL_Reg tbl[] = {
                {"workid", _get_workid},
                {"socket_connect", _socket_connect},
                {"socket_close", _socket_close},
                {"socket_shutdown", _socket_shutdown},
                {"socket_recv", _socket_recv},
                {"socket_send", _socket_send},
                {"timer_add", _timer_add},
                {"timer_register", _timer_register},
                {NULL, NULL},
        };
 
        luaL_checkversion(L);


        luaL_newmetatable(L, "silly_message");
        luaL_newmetatable(L, "silly_message_timer");
        luaL_newmetatable(L, "silly_socket_packet");

        lua_rawgeti(L, LUA_REGISTRYINDEX, LUA_RIDX_MAINTHREAD);
        lua_State *m = lua_tothread(L, -1);
        lua_pop(L, 1);

        lua_pushlightuserdata(L, (void *)m);
        lua_gettable(L, LUA_REGISTRYINDEX);
        struct silly_worker *w = lua_touserdata(L, -1);
        assert(w);

        silly_worker_register(w, _process_msg);

        luaL_newlibtable(L, tbl);
        lua_pushlightuserdata(L, (void *)w);
        luaL_setfuncs(L, tbl, 1);
        

        return 1;
}
