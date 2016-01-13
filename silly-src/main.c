#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <signal.h>
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>
#include <string.h>
#include "silly_config.h"
#include "silly_env.h"
#include "silly_run.h"

#define ARRAY_SIZE(a)   (sizeof(a) / sizeof(a[0]))

static int
_get_int(lua_State *L, const char *key)
{
        int value;
        lua_getfield(L, -1, key);
        value = luaL_checkinteger(L, -1);
        lua_pop(L, 1);
        return value;
}

static const char *
_get_sz(lua_State *L, const char *key)
{
        const char *sz;
        lua_getfield(L, -1, key);
        sz = luaL_checkstring(L, -1);
        lua_pop(L, 1);
        return sz;
}

static int 
_get_ports(lua_State *L, struct silly_listen *listen, int count)
{
        int i;

        lua_settop(L, 1);
        lua_getfield(L, -1, "listen");
        lua_pushnil(L);
        for (i = 0; (i < count) && lua_next(L, -2) != 0; i++) {
                snprintf(listen[i].name, ARRAY_SIZE(listen[i].name), 
                                "listen.%s", luaL_checkstring(L, -2));
                strncpy(listen[i].addr, luaL_checkstring(L, -1), ARRAY_SIZE(listen[i].addr));
                lua_pop(L, 1);
        }

        lua_pop(L, 1);

        return i;
}

static void
_init_env_tbl(lua_State *L, char *key, char *curr)
{
        lua_pushnil(L);
        while (lua_next(L, -2) != 0) {
                const char *k;
                if (lua_type(L, -2) != LUA_TSTRING) {
                        fprintf(stderr, "Invalid config file\n");
                        exit(-1);
                }

                k = lua_tostring(L, -2);
                int n = sprintf(curr, "%s", k);
                if (lua_type(L, -1) == LUA_TTABLE) {
                        curr[n] = '.';
                        _init_env_tbl(L, key, &curr[n + 1]);
                } else {
                        const char *value = lua_tostring(L, -1);
                        if (value == NULL) {
                                fprintf(stderr, "Invalid config table key = %s\n", key);
                                exit(-1);
                        }
                        silly_env_set(key, value);
                }
                
                lua_pop(L, 1);
        };

        return ;
}

static void
_init_env(lua_State *L)
{
        char name[128] = {0};
        
        return _init_env_tbl(L, name, name);
}

static void
_parse_config(lua_State *L, struct silly_config *config)
{
        const char *sz;
        config->debug = _get_int(L, "debug");
        config->daemon = _get_int(L, "daemon");
        config->listen_count = _get_ports(L, config->listen, ARRAY_SIZE(config->listen));
        config->worker_count = _get_int(L, "worker_count");
        sz = _get_sz(L, "bootstrap");
        strncpy(config->bootstrap, sz, ARRAY_SIZE(config->bootstrap));
        sz = _get_sz(L, "lualib_path");
        strncpy(config->lualib_path, sz, ARRAY_SIZE(config->lualib_path));
        sz = _get_sz(L, "lualib_cpath");
        strncpy(config->lualib_cpath, sz, ARRAY_SIZE(config->lualib_cpath));
 
#if 0
        printf("config->debug:%d\n", config->debug);
        printf("config->daemon:%d\n", config->daemon);
        printf("config->listen_count:%d\n", config->listen_count);
        for (int i = 0; i < config->listen_count; i++)
                printf("config->listen:%s(%s)", config->listen[i].name, config->listen[i].addr);
        printf("config->worker_count:%d\n", config->worker_count);
        printf("config->bootstrap:%s\n", config->bootstrap);
        printf("config->lualib_path:%s\n", config->lualib_path);
        printf("config->lualib_cpath:%s\n", config->lualib_cpath);
#endif

        return;
}

static const char *load_config = "\
                                local config_file = ...\
                                local f = assert(io.open(config_file, 'r'))\
                                local code = assert(f:read('a'), 'read config file error')\
                                f:close()\
                                local config = {}\
                                assert(load(code, '=(load)', 't', config))()\
                                return config\
                                ";

int main(int argc, char *argv[])
{
        int err;
        struct silly_config config;
        const char *config_file;
        lua_State *L;
        
        if (argc != 2) {
                fprintf(stderr, "USAGE:silly <config file>\n");
                return -1;
        }
        config_file = argv[1];

        silly_env_init();
        L = luaL_newstate();
        luaL_openlibs(L);
        err = luaL_loadstring(L, load_config);
        lua_pushstring(L, config_file);
        assert(err == LUA_OK);
        err = lua_pcall(L, 1, 1, 0);
        if (err != LUA_OK) {
                fprintf(stderr, "parse config file:%s fail,%s\n", argv[1], lua_tostring(L, -1));
                lua_close(L);
                return -1;
        }
        
        _init_env(L);
        _parse_config(L, &config);
        silly_run(&config);

        lua_close(L);
        silly_env_exit();

        return 0;
}
