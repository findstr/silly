#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <signal.h>
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>
#include <string.h>
#include "silly.h"
#include "silly_malloc.h"
#include "silly_env.h"
#include "silly_run.h"

#define ARRAY_SIZE(a)   (sizeof(a) / sizeof(a[0]))

static void
checktype(lua_State *L, const char *key, int skt, int type)
{
        if (lua_type(L, skt) != type) {
                const char *expect = lua_typename(L, type);
                const char *got = lua_typename(L, lua_type(L, skt));
                const char *fmt = "%s expected %s but got %s\n";
                fprintf(stderr, fmt, key, expect, got);
                exit(-1);
        }

}

static int
getint(lua_State *L, const char *key)
{
        int n;
        lua_getfield(L, -1, key);
        checktype(L, key, -1, LUA_TNUMBER);
        n = lua_tonumber(L, -1);
        lua_pop(L, 1);
        return n;
}

static const char *
getstr(lua_State *L, const char *key, size_t *sz)
{
        const char *str;
        lua_getfield(L, -1, key);
        checktype(L, key, -1, LUA_TSTRING);
        str = lua_tolstring(L, -1, sz);
        lua_pop(L, 1);
        return str;
}

static void
enveach(lua_State *L, char *curr, char *end)
{
        lua_pushnil(L);
        while (lua_next(L, -2) != 0) {
                size_t sz;
                const char *k;
                checktype(L, "[enveach] key", -2, LUA_TSTRING);
                k = lua_tolstring(L, -2, &sz);
                assert(curr <= end);
                if (sz >= (end - curr)) {
                        fprintf(stderr, "[enveach] buff is too short\n");
                        exit(-1);
                }
                memcpy(curr, k, sz);
                if (lua_type(L, -1) == LUA_TTABLE) {
                        curr[sz] = '.';
                        enveach(L, &curr[sz + 1], end);
                } else {
                        int type = lua_type(L, -1);
                        if (type != LUA_TSTRING && type != LUA_TNUMBER) {
                                const char *fmt = "[enveach]"
                                        "%s expect string/number bug got:%s\n";
                                fprintf(stderr, fmt, lua_typename(L, type));
                        }
                        const char *value = lua_tostring(L, -1);
                        curr[sz] = '\0';
                        silly_env_set(k, value);
                }
                lua_pop(L, 1);
        }
        return ;
}

static void
initenv(lua_State *L)
{
        char name[128] = {0};
        return enveach(L, name, &name[128]);
}

static void
parseconfig(lua_State *L, struct silly_config *config)
{
        const char *str;
        size_t sz;
        config->daemon = getint(L, "daemon");
        str = getstr(L, "bootstrap", &sz);
        if (sz >= ARRAY_SIZE(config->bootstrap)) {
                fprintf(stderr, "[parseconfig] bootstrap is too long\n");
                exit(-1);
        }
        memcpy(config->bootstrap, str, sz + 1);
        str = getstr(L, "lualib_path", &sz);
        if (sz >= ARRAY_SIZE(config->lualib_path)) {
                fprintf(stderr, "[parseconfig] lualib_path is too long\n");
                exit(-1);
        }
        memcpy(config->lualib_path, str, sz + 1);
        str = getstr(L, "lualib_cpath", &sz);
        memcpy(config->lualib_cpath, str, sz + 1);
 
#if 0
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
        lua_State *L;
        struct silly_config config;
        if (argc != 2) {
                fprintf(stderr, "USAGE:%s <config file>\n", argv[0]);
                return -1;
        }
        silly_env_init();
        L = luaL_newstate();
        luaL_openlibs(L);
        err = luaL_loadstring(L, load_config);
        lua_pushstring(L, argv[1]);
        assert(err == LUA_OK);
        err = lua_pcall(L, 1, 1, 0);
        if (err != LUA_OK) {
                fprintf(stderr, "%s parse config file:%s fail,%s\n",
                                argv[0], argv[1], lua_tostring(L, -1));
                lua_close(L);
                return -1;
        }
        initenv(L);
        config.selfname = argv[0];
        parseconfig(L, &config);
        lua_close(L);
        silly_run(&config);
        silly_env_exit();
        printf("%s exit, leak memory size:%zu\n",
                        argv[0], silly_memstatus());
        return 0;
}
