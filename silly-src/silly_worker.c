#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>

#include "silly.h"
#include "compiler.h"
#include "atomic.h"
#include "silly_log.h"
#include "silly_malloc.h"
#include "silly_queue.h"
#include "silly_monitor.h"
#include "silly_worker.h"

#ifndef max
#define max(a, b) ((a) > (b) ? (a) : (b))
#endif
#define WARNING_THRESHOLD (64)

struct silly_worker {
	int argc;
	char **argv;
	lua_State *L;
	lua_State *running;
	uint32_t id;
	uint32_t process_id;
	size_t maxmsg;
	lua_Hook oldhook;
	int openhook;
	int oldmask;
	int oldcount;
	struct silly_queue *queue;
	void (*callback)(lua_State *L, struct silly_message *msg);
};

struct silly_worker *W;

void silly_worker_push(struct silly_message *msg)
{
	size_t sz;
	sz = silly_queue_push(W->queue, msg);
	if (unlikely(sz > W->maxmsg)) {
		W->maxmsg *= 2;
		silly_log_warn("[worker] may overload, "
			       "message queue length:%zu\n",
			       sz);
	}
}

void silly_worker_dispatch()
{
	struct silly_message *msg;
	struct silly_message *tmp;
	msg = silly_queue_pop(W->queue);
	atomic_add(&W->process_id, 1);
	if (msg == NULL) {
#ifdef LUA_GC_STEP
		lua_gc(W->L, LUA_GCSTEP, LUA_GC_STEP);
#endif
		return;
	}
	do {
		do {
			atomic_add(&W->process_id, 1);
			W->callback(W->L, msg);
			tmp = msg;
			msg = msg->next;
			silly_message_free(tmp);
		} while (msg);
		msg = silly_queue_pop(W->queue);
	} while (msg);
	W->maxmsg = WARNING_THRESHOLD;
	return;
}

uint32_t silly_worker_genid()
{
	uint32_t id = ++W->id;
	if (unlikely(id == 0))
		silly_log_warn("[worker] genid wraps around\n");
	return id;
}

size_t silly_worker_msgsize()
{
	return silly_queue_size(W->queue);
}

void silly_worker_callback(void (*callback)(struct lua_State *L,
					    struct silly_message *msg))
{
	assert(callback);
	W->callback = callback;
	return;
}

static void setlibpath(lua_State *L, const char *pathname, const char *libpath)
{
	size_t sz1;
	size_t sz2 = strlen(libpath);
	size_t need_sz;
	const char *path;
	if (sz2 == 0)
		return;
	lua_getglobal(L, "package");
	lua_getfield(L, -1, pathname);
	path = luaL_checklstring(L, -1, &sz1);
	need_sz = sz2 + sz1 + 1;
	char new_path[need_sz];
	snprintf(new_path, need_sz, "%s;%s", libpath, path);
	lua_pushstring(L, new_path);
	lua_setfield(L, -3, pathname);
	//clear the stack
	lua_settop(L, 0);
	return;
}

static void *lua_alloc(void *ud, void *ptr, size_t osize, size_t nsize)
{
	(void)ud;
	(void)osize;
	if (nsize == 0) {
		silly_free(ptr);
		return NULL;
	} else {
		return silly_realloc(ptr, nsize);
	}
}

static int ltraceback(lua_State *L)
{
	const char *str = luaL_checkstring(L, 1);
	luaL_traceback(L, L, str, 1);
	return 1;
}

static void fetch_core_start(lua_State *L)
{
	lua_getglobal(L, "require");
	lua_pushstring(L, "core");
	if (lua_pcall(L, 1, 1, 0) != LUA_OK) {
		silly_log_error("[worker] require core fail,%s\n",
				lua_tostring(L, -1));
		exit(-1);
	}
	lua_getfield(L, -1, "start");
	lua_remove(L, -2);
}

void silly_worker_start(const struct silly_config *config)
{
	int err;
	int dir_len;
	int lib_len;
	lua_State *L = lua_newstate(lua_alloc, NULL);
	luaL_openlibs(L);
	W->argc = config->argc;
	W->argv = config->argv;
#if LUA_GC_MODE == LUA_GC_INC
	lua_gc(L, LUA_GCINC, 0, 0, 0);
#else
	lua_gc(L, LUA_GCGEN, 0, 0);
#endif
	//set load path
	lib_len =
		max(sizeof("lualib/?.lua"), sizeof("luaclib/?" LUA_LIB_SUFFIX));
	dir_len = config->selfname - config->selfpath;
	char buf[dir_len + lib_len];
	setlibpath(L, "path", config->lualib_path);
	setlibpath(L, "cpath", config->lualib_cpath);
	setlibpath(L, "path", "./lualib/?.lua");
	setlibpath(L, "cpath", "./luaclib/?" LUA_LIB_SUFFIX);
	memcpy(buf, config->selfpath, dir_len);
	memcpy(buf + dir_len, "lualib/?.lua", sizeof("lualib/?.lua"));
	setlibpath(L, "path", buf);
	memcpy(buf + dir_len, "luaclib/?" LUA_LIB_SUFFIX,
	       sizeof("luaclib/?" LUA_LIB_SUFFIX));
	setlibpath(L, "cpath", buf);
	//exec core.start()
	lua_pushcfunction(L, ltraceback);
	fetch_core_start(L);
	err = luaL_loadfile(L, config->bootstrap);
	if (unlikely(err)) {
		silly_log_error("[worker] load %s %s\n", config->bootstrap,
				lua_tostring(L, -1));
		lua_close(L);
		exit(-1);
	}
	if (unlikely(lua_pcall(L, 1, 0, 1))) {
		silly_log_error("[worker] call %s %s\n", config->bootstrap,
				lua_tostring(L, -1));
		lua_close(L);
		exit(-1);
	}
	W->L = L;
	return;
}

void silly_worker_init()
{
	W = (struct silly_worker *)silly_malloc(sizeof(*W));
	memset(W, 0, sizeof(*W));
	W->maxmsg = WARNING_THRESHOLD;
	W->queue = silly_queue_create();
	return;
}

char **silly_worker_args(int *argc)
{
	*argc = W->argc;
	return W->argv;
}

void silly_worker_resume(lua_State *L)
{
	W->running = L;
}

uint32_t silly_worker_processid()
{
	return W->process_id;
}

static void warn_hook(lua_State *L, lua_Debug *ar)
{
	(void)ar;
	if (W->openhook == 0)
		return;
	int top = lua_gettop(L);
	luaL_traceback(L, L, "maybe in an endless loop.", 1);
	silly_log_warn("[worker] %s\n", lua_tostring(L, -1));
	lua_settop(L, top);
	lua_sethook(L, W->oldhook, W->oldmask, W->oldcount);
	W->openhook = 0;
}

void silly_worker_warnendless()
{
	if (W->running == NULL)
		return;
	W->openhook = 1;
	W->oldhook = lua_gethook(W->running);
	W->oldmask = lua_gethookmask(W->running);
	W->oldcount = lua_gethookcount(W->running);
	lua_sethook(W->running, warn_hook,
		    LUA_MASKCALL | LUA_MASKRET | LUA_MASKCOUNT, 1);
}

void silly_worker_exit()
{
	lua_close(W->L);
	silly_queue_free(W->queue);
	silly_free(W);
}
