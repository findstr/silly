#include <lua.h>
#include <lauxlib.h>

//come frome lsha1.c
int lsha1(lua_State *L);

int luaopen_crypt(lua_State *L)
{
        luaL_Reg tbl[] = {
                {"sha1", lsha1},
                {NULL, NULL},
        };

        luaL_newlib(L, tbl);
        
        return 1;
}
