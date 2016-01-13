#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>

#include "silly_config.h"
#include "silly_malloc.h"
#include "silly_queue.h"
#include "silly_debug.h"

#include "silly_worker.h"

#define max(a, b)       ((a) > (b) ? (a) : (b))


struct silly_worker {
        int                             workid;
        struct silly_queue              *queue;
        lua_State                       *L;
        const struct silly_config       *config;
        void                            (*process_cb)(lua_State *L, struct silly_message *msg);
        void                            (*exit)(lua_State *L);
};

struct silly_worker *silly_worker_create(int workid)
{
        struct silly_worker *w = (struct silly_worker *)silly_malloc(sizeof(*w));
        memset(w, 0, sizeof(*w));

        w->workid = workid;
        w->queue = silly_queue_create();

        return w;
}

void silly_worker_free(struct silly_worker *w)
{
        silly_queue_free(w->queue);
        silly_free(w);

        return ;
}

int silly_worker_getid(struct silly_worker *w)
{
        return w->workid;
}

int silly_worker_push(struct silly_worker *w, struct silly_message *msg)
{
        return silly_queue_push(w->queue, msg); 
}

static void
_process(struct silly_worker *w, struct silly_message *msg)
{
        assert(w->process_cb);
        switch (msg->type) {
        case SILLY_DEBUG:
                silly_debug_process(w->L, msg);
                break;
        default: //forward to lua
                w->process_cb(w->L, msg);
        }

        silly_free(msg);
}

int silly_worker_dispatch(struct silly_worker *w)
{
        struct silly_message *msg;
        
        msg = silly_queue_pop(w->queue);
        while (msg) {
                _process(w, msg);
                msg = silly_queue_pop(w->queue);
        }
        
        return 0;
}

static int
_set_lib_path(lua_State *L, const char *libpath, const char *clibpath)
{
        const char *path;
        const char *cpath;
        size_t sz1 = strlen(libpath);
        size_t sz2 = strlen(clibpath);
        size_t sz3;
        size_t sz4;
        size_t need_sz;

        lua_getglobal(L, "package");
        lua_getfield(L, -1, "path");
        path = luaL_checklstring(L, -1, &sz3);

        lua_getfield(L, -2, "cpath");
        cpath = luaL_checklstring(L, -1, &sz4);

        need_sz = max(sz1, sz2) + max(sz3, sz4) + 1;
        char new_path[need_sz];

        snprintf(new_path, need_sz, "%s;%s", libpath, path);
        lua_pushstring(L, new_path);
        lua_setfield(L, -4, "path");

        snprintf(new_path, need_sz, "%s;%s", clibpath, cpath);
        lua_pushstring(L, new_path);
        lua_setfield(L, -4, "cpath");

        //clear the stack
        lua_settop(L, 0);

        return 0;
}

int silly_worker_start(struct silly_worker *w, const struct silly_config *config)
{
        lua_State *L = luaL_newstate();
        luaL_openlibs(L);

        lua_pushlightuserdata(L, (void *)L);
        lua_pushlightuserdata(L, w);
        lua_settable(L, LUA_REGISTRYINDEX);

        if (_set_lib_path(L, config->lualib_path, config->lualib_cpath) != 0) {
                fprintf(stderr, "set lua libpath fail,%s\n", lua_tostring(L, -1));
                lua_close(L);
                return -1;
        }

	lua_gc(L, LUA_GCRESTART, 0);
        if (luaL_loadfile(L, config->bootstrap) || lua_pcall(L, 0, 0, 0)) {
                fprintf(stderr, "call main.lua fail,%s\n", lua_tostring(L, -1));
                lua_close(L);
                return -1;
        }

        w->L = L;
 
        return 0;
}

void silly_worker_stop(struct silly_worker *w)
{
        if (w->exit)
                w->exit(w->L);

        return ;
}


void silly_worker_message(struct silly_worker *w, void (*msg)(struct lua_State *L, struct silly_message *msg))
{
        assert(msg);
        w->process_cb = msg;

        return ;
}

void silly_worker_exit(struct silly_worker *w, void (*exit)(struct lua_State *L))
{
        assert(exit);
        w->exit = exit;
        
        return ;
}


