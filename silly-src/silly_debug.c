#include <stdio.h>
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>

#include "silly_message.h"

#include "silly_debug.h"

const char require[] = 
        "local filename = ...\n"
        "local function clone(dst, src)\n"
        "       for k, v in pairs(src) do\n"
        "              dst[k] = v\n"
        "       end\n"
        "end\n"
        "local old = package.loaded[filename]\n"
        "if old == nil then\n"
        "       old = {}\n"
        "end\n"
        "package.loaded[filename] = nil\n"
        "local new = require(filename)\n"
        "clone(old, new)\n"
        "package.loaded[filename] = old\n";

void silly_debug_process(lua_State *L, struct silly_message *msg)
{
        char filename[256];
        char *sz = (char *)(msg + 1);

        if (sscanf(sz, "require(\"%[^\"]", filename) != 1)
                return ;

        luaL_loadstring(L, require);
        lua_pushstring(L, filename);

        if (lua_pcall(L, 1, 0, 0) != 0)
                fprintf(stderr, "_debug_procee call fail:%s\n", lua_tostring(L, -1));

        return ;
}

