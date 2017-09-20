#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>

#include "silly.h"
#include "compiler.h"
#include "silly_log.h"
#include "silly_malloc.h"
#include "silly_queue.h"
#include "silly_worker.h"

#define max(a, b)	((a) > (b) ? (a) : (b))


struct silly_worker {
	lua_State *L;
	uint32_t id;
	size_t maxmsg;
	struct silly_queue *queue;
	void (*callback)(lua_State *L, struct silly_message *msg);
};

struct silly_worker *W;


void
silly_worker_push(struct silly_message *msg)
{
	size_t sz;
	sz = silly_queue_push(W->queue, msg);
	if (unlikely(sz > W->maxmsg)) {
		W->maxmsg *= 2;
		silly_log("may overload, now message size is:%zu\n", sz);
	}
}

void
silly_worker_dispatch()
{
	struct silly_message *msg;
	struct silly_message *tmp;
	msg = silly_queue_pop(W->queue);
	while (msg) {
		assert(W->callback);
		W->callback(W->L, msg);
		tmp = msg;
		msg = msg->next;
		silly_message_free(tmp);
	}
	return ;
}

uint32_t
silly_worker_genid()
{
	return W->id++;
}

size_t
silly_worker_msgsize()
{
	return silly_queue_size(W->queue);
}

void
silly_worker_callback(void (*callback)(struct lua_State *L, struct silly_message *msg))
{
	assert(callback);
	W->callback = callback;
	return ;
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

static void *
lua_alloc(void *ud, void *ptr, size_t osize, size_t nsize)
{
	(void) ud;
	(void) osize;
	if (nsize == 0) {
		silly_free(ptr);
		return NULL;
	} else {
		return silly_realloc(ptr, nsize);
	}
}

void
silly_worker_start(const struct silly_config *config)
{
	int err;
	lua_State *L = lua_newstate(lua_alloc, NULL);
	luaL_openlibs(L);
	err = setlibpath(L, config->lualib_path, config->lualib_cpath);
	if (unlikely(err != 0)) {
		silly_log("silly worker set lua libpath fail,%s\n",
			lua_tostring(L, -1));
		lua_close(L);
		exit(-1);
	}
	lua_gc(L, LUA_GCRESTART, 0);
	err = luaL_loadfile(L, config->bootstrap);
	if (unlikely(err) || unlikely(lua_pcall(L, 0, 0, 0))) {
		silly_log("silly worker call %s fail,%s\n",
			config->bootstrap, lua_tostring(L, -1));
		lua_close(L);
		exit(-1);
	}
	W->L = L;
	return ;
}

void
silly_worker_init()
{
	W = (struct silly_worker *)silly_malloc(sizeof(*W));
	memset(W, 0, sizeof(*W));
	W->maxmsg = 128;
	W->queue = silly_queue_create();
	return ;
}

void
silly_worker_exit()
{
	lua_close(W->L);
	silly_queue_free(W->queue);
	silly_free(W);
}

