#include <stdio.h>
#include <lua.h>
#include <lauxlib.h>

static int
_socket_pull(lua_State *L)
{
        printf("lua-pull\n");

        return 0;
}

static int
_socket_push(lua_State *L)
{
        printf("lua-push\n");

        return 0;
}



int luaopen_server(lua_State *L)
{
        luaL_Reg tbl[] = {
                {"pull", _socket_pull},
                {"push", _socket_push},
                {NULL, NULL},
        };

        luaL_newlib(L, tbl);
        
        return 1;
}
