#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>

#include "silly_malloc.h"
#include "silly_queue.h"
#include "silly_worker.h"

#define max(a, b)       ((a) > (b) ? (a) : (b))


struct silly_worker {
        int                     workid;
        struct silly_queue      *queue;
        lua_State               *L;
        void                    (*socket_cb)(lua_State *L, void *msg);
        void                    (*timer_cb)(lua_State *L, void *msg);
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
_free_timer_msg(struct silly_message_timer *t)
{
        silly_free(t);
}

static void
_free_socket_msg(struct silly_message_socket *s)
{
        silly_free(s->data);
        silly_free(s);
}

static void
_process_socket(struct silly_worker *w, struct silly_message_socket *s)
{
        if (w->socket_cb)
                w->socket_cb(w->L, s);
        _free_socket_msg(s);
}

static void
_process_timer(struct silly_worker *w, struct silly_message_timer *t)
{
        if (w->timer_cb)
                w->timer_cb(w->L, t);
        _free_timer_msg(t);
}

static void
_process(struct silly_worker *w, struct silly_message *msg)
{
        switch (msg->type) {
        case SILLY_MESSAGE_TIMER:
                //fprintf(stderr, "silly_worker:_process:%d\n", w->workid);
                _process_timer(w, msg->msg.timer);
                break;
        case SILLY_MESSAGE_SOCKET:
                //fprintf(stderr, "silly_worker:_process:socket\n");
                _process_socket(w, msg->msg.socket);
                break;
        default:
                fprintf(stderr, "silly_worker:_process:unknow message type:%d\n", msg->type);
                assert(0);
                break;
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
        
        lua_gc(w->L, LUA_GCSTEP, 0);

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

        return 0;
}

int silly_worker_start(struct silly_worker *w, const char *bootstrap, const char *libpath, const char *clibpath)
{
        lua_State *L = luaL_newstate();
        luaL_openlibs(L);

        lua_pushlightuserdata(L, (void *)L);
        lua_pushlightuserdata(L, w);
        lua_settable(L, LUA_REGISTRYINDEX);

        if (_set_lib_path(L, libpath, clibpath) != 0) {
                fprintf(stderr, "set lua libpath fail,%s\n", lua_tostring(L, -1));
                lua_close(L);
                return -1;
        }

        if (luaL_loadfile(L, bootstrap) || lua_pcall(L, 0, 0, 0)) {
                fprintf(stderr, "call main.lua fail,%s\n", lua_tostring(L, -1));
                lua_close(L);
                return -1;
        }

        w->L = L;
 
        return 0;
}


void silly_worker_register(struct silly_worker *w, enum silly_message_type type, void (*cb)(struct lua_State *L, void *msg))
{
        switch (type) {
        case SILLY_MESSAGE_SOCKET:
                w->socket_cb = cb;            
                break;
        case SILLY_MESSAGE_TIMER:
                w->timer_cb = cb;
                break;
        default:
                fprintf(stderr, "silly_worker:silly_work_regiser:unkonw message type:%d\n", type);
                break;
        }
}


