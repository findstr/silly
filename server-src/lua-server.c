#include <assert.h>
#include <stdlib.h>
#include <lua.h>
#include <lauxlib.h>

#include "timer.h"
#include "event.h"

//lua function --> function hanlder(type, fd, data)
static int
_socket_recv_handler(void *ud, enum event_ptype type, int fd, const char *data, int size)
{
        int err;
        lua_State *L = (lua_State *)ud;
        lua_pushlightuserdata(L, _socket_recv_handler);
        lua_gettable(L, LUA_REGISTRYINDEX);

        lua_pushinteger(L, type);
        lua_pushinteger(L, fd);
        assert(data);
        lua_pushlstring(L, data, size);

        err = lua_pcall(L, 3, 0, 0);
        if (err < 0)
                fprintf(stderr, "socket_recv call failes:%s\n", lua_tostring(L, -1));

        return 0;
}

static int
_socket_recv(lua_State *L)
{
        lua_pushlightuserdata(L, _socket_recv_handler);
        lua_insert(L, -2);
        lua_settable(L, LUA_REGISTRYINDEX);
         
        return 2;
}

static int
_socket_send(lua_State *L)
{
        int fd;
        size_t size;
        const char *data;

        fd = luaL_checkinteger(L, 1);
        data = luaL_checklstring(L, 2, &size);
        if (data == NULL)
                luaL_argerror(L, 2, "'data' should be a lstring\n");

        if (fd < 0)
                luaL_argerror(L, 1, "'fd' should be a valid socket fd\n");

        event_socketsend(EVENT_GDATA, fd, data, size);

        return 0;
}

struct timer_ud {
        lua_State *L;
};

static void 
_timer_handler(void *ud)
{
        int err;
        struct timer_ud *t = (struct timer_ud *)ud;

        lua_pushlightuserdata(t->L, t);
        lua_gettable(t->L, LUA_REGISTRYINDEX);

        err = lua_pcall(t->L, 0, 0, 0);
        if (err < 0)
                fprintf(stderr, "timer handler call failes:%s\n", lua_tostring(t->L, -1));

        free(ud);

        return;
}

static int
_timer_add(lua_State *L)
{
        int time = luaL_checkinteger(L, 1);
        struct timer_ud *u = (struct timer_ud *)malloc(sizeof(*u));
        u->L = L;

        lua_pushlightuserdata(L, u);
        lua_insert(L, -2);
        lua_settable(L, LUA_REGISTRYINDEX);

        return timer_add(time, _timer_handler, u);
}

int luaopen_server(lua_State *L)
{
        luaL_Reg tbl[] = {
                {"recv", _socket_recv},
                {"send", _socket_send},
                {"addtimer", _timer_add},
                {NULL, NULL},
        };

        event_set_datahandler(_socket_recv_handler, L);

        luaL_newlib(L, tbl);
        
        return 1;
}
