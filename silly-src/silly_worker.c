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
        struct silly_queue              *queue;
        lua_State                       *L;
        void                            (*callback)(lua_State *L, struct silly_message *msg);
        uint32_t                        id;
        int                             quit;
};

struct silly_worker *W;


void 
silly_worker_push(struct silly_message *msg)
{
        silly_queue_push(W->queue, msg);
}

void
silly_worker_dispatch()
{
        struct silly_message *msg;
        msg = silly_queue_pop(W->queue);
        while (msg) {
                assert(W->callback);
                W->callback(W->L, msg);
                silly_free(msg);
                msg = silly_queue_pop(W->queue);
        }
        return ;
}

uint32_t
silly_worker_genid()
{
        return W->id++;
}

void 
silly_worker_callback(void (*callback)(struct lua_State *L, struct silly_message *msg))
{
        assert(callback);
        W->callback = callback;
        return ;
}

void
silly_worker_quit()
{
        W->quit = 1;
}

int silly_worker_checkquit()
{
        return W->quit;
}

static int
setlibpath(lua_State *L, const char *libpath, const char *clibpath)
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

static void
initlua(struct silly_config *config)
{
        lua_State *L = luaL_newstate();
        luaL_openlibs(L);

        if (setlibpath(L, config->lualib_path, config->lualib_cpath) != 0) {
                fprintf(stderr, "silly worker set lua libpath fail,%s\n", lua_tostring(L, -1));
                lua_close(L);
                exit(-1);
        }
	lua_gc(L, LUA_GCRESTART, 0);
        if (luaL_loadfile(L, config->bootstrap) || lua_pcall(L, 0, 0, 0)) {
                fprintf(stderr, "silly worker call %s fail,%s\n", config->bootstrap, lua_tostring(L, -1));
                lua_close(L);
                exit(-1);
        }
        W->L = L;
        return ;
}

void 
silly_worker_init(struct silly_config *config)
{
        W = (struct silly_worker *)silly_malloc(sizeof(*W));
        memset(W, 0, sizeof(*W));
        W->queue = silly_queue_create();
        initlua(config);
        return ;
}

void 
silly_worker_exit()
{
        lua_close(W->L);
        silly_queue_free(W->queue);
        silly_free(W);
}

