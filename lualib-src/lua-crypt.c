#include <lua.h>
#include <lauxlib.h>

//come frome lsha1.c
int lsha1(lua_State *L);

static int
_randomkey(lua_State *L)
{
        int i;
        char buff[8];

        for (i = 0; i < 8; i++)
                buff[i] = random() % 26 + 'a';
        
        lua_pushlstring(L, buff, 8);

        return 1;
}

int luaopen_crypt(lua_State *L)
{
        luaL_Reg tbl[] = {
                {"sha1", lsha1},
                {"randomkey", _randomkey},
                {NULL, NULL},
        };

        luaL_newlib(L, tbl);
        
        return 1;
}
