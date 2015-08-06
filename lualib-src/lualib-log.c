#include <lua.h>
#include <stdio.h>
#include <lauxlib.h>
#include <lualib.h>
#include <unistd.h>
#include <time.h>
#include <stdio.h>

static int
_open(lua_State *L)
{
        FILE *fp;
        const char *path = luaL_checkstring(L, 1);
        fp = fopen(path, "wb+");

        lua_pushlightuserdata(L, fp);

        return 1;
}

static int
_add(lua_State *L)
{
        FILE *fp;
        time_t now;
        struct tm timenow;
        
        fp = (FILE *)lua_topointer(L, 1);
        const char *level = luaL_checkstring(L, 2);
        const char *log = luaL_checkstring(L, 3);

        time(&now);
        localtime_r(&now, &timenow);
 
        fprintf(fp, "%d-%d-%d %d:%d:%d:[%s]%s\n",
                        timenow.tm_year + 1900,
                        timenow.tm_mon + 1,
                        timenow.tm_mday,
                        timenow.tm_hour,
                        timenow.tm_min,
                        timenow.tm_sec,
                        level,
                        log);

        return 0;
}

static int
_sync(lua_State *L)
{
        FILE *fp;
        
        fp = (FILE *)lua_topointer(L, 1);
        fflush(fp);

        return 0;
}

static int
_close(lua_State *L)
{
        FILE *fp;
        
        fp = (FILE *)lua_topointer(L, 1);

        fclose(fp);

        return 0;
}

int luaopen_log(lua_State *L)
{
        luaL_Reg tbl[] = {
                {"open", _open},
                {"add", _add},
                {"sync", _sync},
                {"close", _close},
                {NULL, NULL},
        };


        luaL_newlib(L, tbl);

        return 1;
}


