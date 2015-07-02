#include <stdlib.h>
#include <lua.h>
#include <lauxlib.h>

#include "socket.h"

static int
_socket_pull(lua_State *L)
{
        int fd;
        int size;
        const char *buff;

        buff = socket_pull(&fd, &size);
        
        lua_pushinteger(L, fd);
        if (buff)
                lua_pushlstring(L, buff, size);
        else
                lua_pushnil(L);

        return 2;
}

static int
_socket_send(lua_State *L)
{
        int fd;
        int size;
        const char *data;

        fd = luaL_checkinteger(L, 1);
        data = luaL_checklstring(L, 2, &size);
        if (data == NULL)
                error(L, "'data' should be a lstring\n");

        if (fd < 0)
                error(L, "'fd' should be a valid socket fd\n");

        socket_send(fd, data, size);

        return 0;
}

int luaopen_server(lua_State *L)
{
        luaL_Reg tbl[] = {
                {"pull", _socket_pull},
                {"send", _socket_send},
                {NULL, NULL},
        };

        luaL_newlib(L, tbl);
        
        return 1;
}
