#include <stdio.h>
#include <stdlib.h>
#include <signal.h>
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>
#include <string.h>
#include "silly_config.h"
#include "silly_run.h"

#define ARRAY_SIZE(a)   (sizeof(a) / sizeof(a[0]))

static int
_get_int(lua_State *L, const char *key)
{
        lua_getglobal(L, key);
        return luaL_checkinteger(L, -1);
}

static const char *
_get_sz(lua_State *L, const char *key)
{
        lua_getglobal(L, key);
        return luaL_checkstring(L, -1);
}

static int 
_get_ports(lua_State *L, struct listen_port *ports, int count)
{
        int i;

        lua_settop(L, 0);
        lua_getglobal(L, "ports");
        lua_pushnil(L);
 
        for (i = 0; (i < count) && lua_next(L, 1) != 0; i++) {
                strncpy(ports[i].name, luaL_checkstring(L, -2), ARRAY_SIZE(ports[i].name));
                ports[i].port = luaL_checkinteger(L, -1);
                lua_pop(L, 1);
        }

        return i;
}


static int
_parse_config(lua_State *L, struct silly_config *config)
{
        const char *sz;
        config->debug = _get_int(L, "debug");
        config->daemon = _get_int(L, "daemon");
        config->listen_count = _get_ports(L, config->ports, ARRAY_SIZE(config->ports));
        config->worker_count = _get_int(L, "worker_count");
        sz = _get_sz(L, "bootstrap");
        strncpy(config->bootstrap, sz, ARRAY_SIZE(config->bootstrap));
        sz = _get_sz(L, "lualib_path");
        strncpy(config->lualib_path, sz, ARRAY_SIZE(config->lualib_path));
        sz = _get_sz(L, "lualib_cpath");
        strncpy(config->lualib_cpath, sz, ARRAY_SIZE(config->lualib_cpath));

        return 0;
}

int main()
{
        struct silly_config config;
        lua_State *L = luaL_newstate();
        if (luaL_loadfile(L, "config") || lua_pcall(L, 0, 0, 0)) {
                fprintf(stderr, "parse config fail,%s\n", lua_tostring(L, -1));
                lua_close(L);
                return -1;
        }
        
        _parse_config(L, &config);
        silly_run(&config);

        return 0;
}
