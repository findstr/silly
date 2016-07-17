#include <assert.h>
#include <stdlib.h>
#include <stdio.h>
#include <sys/time.h>
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>

#include "silly.h"
#include "silly_env.h"
#include "silly_worker.h"
#include "silly_socket.h"
#include "silly_malloc.h"
#include "silly_timer.h"

static void
dispatch(lua_State *L, struct silly_message *sm)
{
        int type;
        int err;
        int args = 1;
        lua_pushlightuserdata(L, dispatch);
        lua_gettable(L, LUA_REGISTRYINDEX);
        type = lua_type(L, -1);
        if (type != LUA_TFUNCTION) {
                fprintf(stderr, "callback need function but got:%d\n", type);
                return ;
        }
        lua_pushinteger(L, sm->type);
        switch (sm->type) {
        case SILLY_TEXPIRE:
                lua_pushinteger(L, texpire(sm)->session);
                lua_pushlightuserdata(L, sm);
                args += 2;
                break;
        case SILLY_SACCEPT:
                lua_pushinteger(L, saccept(sm)->sid);
                lua_pushlightuserdata(L, sm);
                lua_pushinteger(L, saccept(sm)->ud);
                lua_pushstring(L, (char *)saccept(sm)->data);
                args += 4;
                break;
        case SILLY_SCONNECTED:
                lua_pushinteger(L, sconnected(sm)->sid);
                lua_pushlightuserdata(L, sm);
                args += 2;
                break;
        case SILLY_SDATA:
                lua_pushinteger(L, sdata(sm)->sid);
                lua_pushlightuserdata(L, sm);
                args += 2;
                break;
        case SILLY_SCLOSE:
                lua_pushinteger(L, sclose(sm)->sid);
                lua_pushlightuserdata(L, sm);
                lua_pushinteger(L, sclose(sm)->ud);
                args += 3;
                break;
        default:
                fprintf(stderr, "callback unknow message type:%d\n", sm->type);
                assert(0);
                break;
        }
        err = lua_pcall(L, args, 0, 0);
        if (err != LUA_OK) {
                fprintf(stderr, "callback call fail:%s\n", lua_tostring(L, -1));
                lua_pop(L, 1);
        }
        return ;
}



static int
lgetenv(lua_State *L)
{
        const char *key = luaL_checkstring(L, 1);
        const char *value = silly_env_get(key);
        if (value)
                lua_pushstring(L, value);
        else
                lua_pushnil(L);

        return 1;
}

static int
lsetenv(lua_State *L)
{
        const char *key = luaL_checkstring(L, 1);
        const char *value = luaL_checkstring(L, 2);

        silly_env_set(key, value);

        return 0;
}

static int
lquit(lua_State *L)
{
        silly_worker_quit();
        return 0;
}
 
static int
lmemstatus(lua_State *L)
{
        size_t sz;
        sz = silly_memstatus();
        lua_pushinteger(L, sz);
        return 1;
}

static int
ltimeout(lua_State *L)
{
        uint32_t expire;
        uint32_t session;
        expire = luaL_checkinteger(L, 1);
        session = silly_timer_timeout(expire);
        lua_pushinteger(L, session);
        return 1;
}

static int
ltimenow(lua_State *L)
{
        uint64_t now = silly_timer_now();
        lua_pushinteger(L, now);
        return 1;
}

static int
ldispatch(lua_State *L)
{
        lua_pushlightuserdata(L, dispatch);
        lua_insert(L, -2);
        lua_settable(L, LUA_REGISTRYINDEX);
        return 0;
}

static int
lsocket_connect(lua_State *L)
{
        int err;
        int port;
        int bport;
        const char *ip;
        const char *bip;
        ip = luaL_checkstring(L, 1);
        port = luaL_checkinteger(L, 2);
        bip = luaL_checkstring(L, 3);
        bport = luaL_checkinteger(L, 4);
        err = silly_socket_connect(ip, port, bip, bport);
        lua_pushinteger(L, err);
        return 1;
}

static int
lsocket_listen(lua_State *L)
{
        const char *ip = luaL_checkstring(L, 1);
        int port = luaL_checkinteger(L, 2);
        int backlog = luaL_checkinteger(L, 3);
        int err = silly_socket_listen(ip, port, backlog);
        lua_pushinteger(L, err);
        return 1;
}

static int
lsocket_close(lua_State *L)
{
        int err;
        int sid;
        sid = luaL_checkinteger(L, 1);
        err = silly_socket_close(sid);
        lua_pushboolean(L, err < 0 ? 0 : 1);
        return 1;
}

static int
lsocket_send(lua_State *L)
{
        int err;
        int sid;
        uint8_t *buff;
        int size;
        sid = luaL_checkinteger(L, 1);
        buff = lua_touserdata(L, 2);
        size = luaL_checkinteger(L, 3);
        err = silly_socket_send(sid, buff, size);
        lua_pushboolean(L, err < 0 ? 0 : 1);
        return 1;
}

static int
ldropmsg(lua_State *L)
{
        struct silly_message *m = (struct silly_message *)lua_touserdata(L, 1);
        if (m->type == SILLY_SDATA) {
                assert(tosocket(m)->data);
                silly_free(tosocket(m)->data);
        }
        return 0;
}

static int
ltostring(lua_State *L)
{
        char *buff;
        int size;
        buff = lua_touserdata(L, 1);
        size = luaL_checkinteger(L, 2);
        lua_pushlstring(L, buff, size);
        return 1;
}

static int
lgenid(lua_State *L)
{
        uint32_t id = silly_worker_genid();
        lua_pushinteger(L, id);
        return 1;
}


int 
luaopen_silly(lua_State *L)
{
        luaL_Reg tbl[] = {
                //core
                {"dispatch",    ldispatch},
                {"getenv",      lgetenv},
                {"setenv",      lsetenv},
                {"quit",        lquit},
                {"memstatus",   lmemstatus},
                //timer
                {"timeout",     ltimeout},
                {"timenow",     ltimenow},
                //socket
                {"socketlisten",        lsocket_listen},
                {"socketconnect",       lsocket_connect},
                {"socketclose",         lsocket_close},
                {"socketsend",          lsocket_send},
                //
                {"dropmessage",         ldropmsg},
                {"tostring",            ltostring},
                {"genid",               lgenid},
                //end
                {NULL, NULL},
        };
 
        luaL_checkversion(L);
        lua_rawgeti(L, LUA_REGISTRYINDEX, LUA_RIDX_MAINTHREAD);
        lua_State *m = lua_tothread(L, -1);
        lua_pop(L, 1);

        lua_pushlightuserdata(L, (void *)m);
        lua_gettable(L, LUA_REGISTRYINDEX);
        silly_worker_callback(dispatch);
        luaL_newlibtable(L, tbl);
        luaL_setfuncs(L, tbl, 0);

        return 1;
}

