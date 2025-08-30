#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <pthread.h>
#include <unistd.h>
#include <stdatomic.h>
#include <time.h>

#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>

#include "silly.h"
#include "compiler.h"
#include "message.h"
#include "spinlock.h"
#include "silly_log.h"
#include "silly_malloc.h"
#include "silly_worker.h"

#define MT_HIVE "core.hive"
#define MT_WORKER "core.hive.worker"

#define UPVAL_HIVE (1)

#ifdef SILLY_TEST
#define IDLE_TIMEOUT (5) //seconds
#else
#define IDLE_TIMEOUT (60) //seconds
#endif

#define THREAD_IDLE    (0)
#define THREAD_WORKING (1)
#define THREAD_DEAD    (-1)

#define MALLOC(size) silly_malloc(size)
#define REALLOC(ptr, size) silly_realloc(ptr, size)
#define FREE(ptr) silly_free(ptr)

#define store(ptr, value) atomic_store_explicit(ptr, value, memory_order_relaxed)
#define load(ptr) atomic_load_explicit(ptr, memory_order_relaxed)
#define add(ptr, value) atomic_fetch_add_explicit(ptr, value, memory_order_relaxed)
#define sub(ptr, value) atomic_fetch_sub_explicit(ptr, value, memory_order_relaxed)
#define release(ptr, value) atomic_store_explicit(ptr, value, memory_order_release)
#define acquire(ptr) atomic_load_explicit(ptr, memory_order_acquire)

struct thread_context;

struct hive {
	uint32_t id;
	atomic_int thread_busy;
	atomic_int worker_waiting;
	int thread_min;
	int thread_max;
	int thread_live;

	uint32_t round_robin;
	int table_capacity;
	struct thread_context **table;
	struct thread_context *wait_for_join;
};

struct worker {
	lua_State *L;
	struct worker *next;
	uint32_t task_id;
	int pcall_status;
};

struct thread_context {
	struct hive *h;
	pthread_t thread_id;
	uint8_t shutdown;
	atomic_int_fast8_t status;
	time_t idle_start;

	pthread_mutex_t lock;
	pthread_cond_t cond;
	struct worker *head;
	struct worker **tail;
	struct thread_context *next;
};

struct task_message {
	struct silly_message hdr;
	struct worker *w;
};

static int MSG_TYPE_HIVE_DONE = 0;

static void copy_value_r(lua_State *L_from, lua_State *L_to, int index, int depth)
{
	if (depth > 100)
		return;
	size_t len;
	const char *s;
	int type = lua_type(L_from, index);
	switch (type) {
	case LUA_TNIL:
		lua_pushnil(L_to);
		break;
	case LUA_TBOOLEAN:
		lua_pushboolean(L_to, lua_toboolean(L_from, index));
		break;
	case LUA_TNUMBER:
		if (lua_isinteger(L_from, index)) {
			lua_pushinteger(L_to, lua_tointeger(L_from, index));
		} else {
			lua_pushnumber(L_to, lua_tonumber(L_from, index));
		}
		break;
	case LUA_TSTRING:
		s = lua_tolstring(L_from, index, &len);
		lua_pushlstring(L_to, s, len);
		break;
	case LUA_TTABLE:
		lua_newtable(L_to);
		lua_pushnil(L_from);
		while (lua_next(L_from, index) != 0) {
			copy_value_r(L_from, L_to, lua_gettop(L_from) - 1, depth + 1);
			copy_value_r(L_from, L_to, lua_gettop(L_from), depth + 1);
			lua_rawset(L_to, -3);
			lua_pop(L_from, 1);
		}
		break;
	default:
		lua_pushnil(L_to);
		break;
	}
}

static inline void copy_values(lua_State *L_from, lua_State *L_to, int stk, int top)
{
	luaL_checkstack(L_to, top - stk + 1, NULL);
	for (int i = stk; i <= top; i++) {
		copy_value_r(L_from, L_to, i, 0);
	}
}

static inline void copy_value(lua_State *from, lua_State *to, int index)
{
	copy_value_r(from, to, index, 0);
}

static int msg_unpack(lua_State *L, struct silly_message *m)
{
	int n;
	struct task_message *tm = container_of(m, struct task_message, hdr);
	lua_pushinteger(L, tm->w->task_id);
	lua_pushboolean(L, tm->w->pcall_status == LUA_OK);
	if (tm->w->pcall_status != LUA_OK) {
		n = 1;
		copy_value(tm->w->L, L, -1);
	} else {
		n = lua_gettop(tm->w->L);
		copy_values(tm->w->L, L, 2, n);
		n = n - 1;
	}
	lua_settop(tm->w->L, 1);
	tm->w->task_id = 0;
	return n + 2;
}

static struct thread_context **try_join_dead_threads(struct hive *h, int force)
{
	struct thread_context *ptr = h->wait_for_join;
	struct thread_context **tail = &h->wait_for_join;
	while (ptr != NULL) {
		struct thread_context *next = ptr->next;
		if (force || acquire(&ptr->status) == THREAD_DEAD) {
			pthread_join(ptr->thread_id, NULL);
			pthread_mutex_destroy(&ptr->lock);
			pthread_cond_destroy(&ptr->cond);
			FREE(ptr);
		} else {
			*tail = ptr;
			tail = &ptr->next;
		}
		ptr = next;
	}
	*tail = NULL;
	return tail;
}

static int l_hive_gc(lua_State *L)
{
	struct hive *h = (struct hive *)lua_touserdata(L, 1);
	if (h->table == NULL) {
		return 0;
	}
	for (int i = 0; i < h->thread_live; i++) {
		struct thread_context *ctx = h->table[i];
		pthread_mutex_lock(&ctx->lock);
		ctx->shutdown = 1;
		pthread_cond_signal(&ctx->cond);
		pthread_mutex_unlock(&ctx->lock);
	}
	try_join_dead_threads(h, 1);
	for (int i = 0; i < h->thread_live; i++) {
		struct thread_context *ctx = h->table[i];
		pthread_join(ctx->thread_id, NULL);
		pthread_mutex_destroy(&ctx->lock);
		pthread_cond_destroy(&ctx->cond);
		FREE(ctx);
	}
	FREE(h->table);
	h->table_capacity = 0;
	h->thread_live = 0;
	return 0;
}

static int l_worker_gc(lua_State *L)
{
	struct worker *w = (struct worker *)lua_touserdata(L, 1);
	if (unlikely(w->task_id != 0)) {
		silly_log_warn("[hive] A worker was still busy during GC. This may cause a memory leak report on exit. "
			"Check for blocking calls or infinite loops in hive tasks.\n");
		// If the worker is still running in the thread pool,
		// the only possible reason it was garbage collected is that its Lua state has been closed.
		// In this case, we can rely on the process exit cleanup to handle it automatically.
		return 0;
	}
	lua_close(w->L);
	w->L = NULL;
	w->task_id = 0;
	return 0;
}

static void new_hive(lua_State *L)
{
	struct hive *h = lua_newuserdatauv(L, sizeof(*h), 0);
	if (luaL_newmetatable(L, MT_HIVE)) {
		lua_pushstring(L, "__gc");
		lua_pushcfunction(L, l_hive_gc);
		lua_settable(L, -3);
	}
	lua_setmetatable(L, -2);

	int n = cpu_count();
	h->id = 0;
	h->thread_live = 0;
	h->round_robin = 0;
	h->table_capacity = n;
	h->table = MALLOC(n * sizeof(h->table[0]));
	for (int i = 0; i < n; i++) {
		h->table[i] = NULL;
	}
	h->thread_min = n;
	h->thread_max = 2 * n;
	h->wait_for_join = NULL;
	atomic_init(&h->thread_busy, 0);
	atomic_init(&h->worker_waiting, 0);
	lua_pushvalue(L, -1);
	lua_rawsetp(L, LUA_REGISTRYINDEX, new_hive);
}

static void *thread_func(void *arg)
{
	struct thread_context *ctx = (struct thread_context *)arg;
	struct hive *h = ctx->h;
	for (;;) {
		struct worker *w;
		struct task_message *msg;

		pthread_mutex_lock(&ctx->lock);
		while (ctx->head == NULL && !ctx->shutdown) {
			ctx->idle_start = time(NULL);
			release(&ctx->status, THREAD_IDLE);
			pthread_cond_wait(&ctx->cond, &ctx->lock);
			release(&ctx->status, THREAD_WORKING);
		}
		if (ctx->shutdown && ctx->head == NULL) {
			pthread_mutex_unlock(&ctx->lock);
			release(&ctx->status, THREAD_DEAD);
			return NULL;
		}
		w = ctx->head;
		ctx->head = w->next;
		if (ctx->head == NULL) {
			ctx->tail = &ctx->head;
		}
		pthread_mutex_unlock(&ctx->lock);
		sub(&h->worker_waiting, 1);
		add(&h->thread_busy, 1);
		w->pcall_status = lua_pcall(w->L, lua_gettop(w->L) - 2, LUA_MULTRET, 0);
		sub(&h->thread_busy, 1);
		msg = (struct task_message *)MALLOC(sizeof(*msg));
		msg->hdr.type = MSG_TYPE_HIVE_DONE;
		msg->hdr.unpack = msg_unpack;
		msg->hdr.free = silly_free;
		msg->w = w;
		silly_worker_push(&msg->hdr);
	}
	return NULL;
}

static void create_thread(struct hive *h)
{
	struct thread_context *ctx = MALLOC(sizeof(*ctx));
	ctx->h = h;
	ctx->shutdown = 0;
	ctx->next = NULL;
	atomic_init(&ctx->status, THREAD_IDLE);
	pthread_mutex_init(&ctx->lock, NULL);
	pthread_cond_init(&ctx->cond, NULL);
	ctx->head = NULL;
	ctx->tail = &ctx->head;
	if (pthread_create(&ctx->thread_id, NULL, thread_func, ctx) != 0) {
		pthread_mutex_destroy(&ctx->lock);
		pthread_cond_destroy(&ctx->cond);
		FREE(ctx);
		return ;
	}
	if (h->thread_live >= h->table_capacity) {
		int n = (h->table_capacity + 1) * 3 / 2;
		assert(h->thread_live == h->table_capacity);
		h->table = REALLOC(h->table, n * sizeof(h->table[0]));
		memset(h->table + h->thread_live, 0, (n - h->thread_live) * sizeof(h->table[0]));
		h->table_capacity = n;
	}
	h->table[h->thread_live++] = ctx;
}

static lua_Integer push_into_hive(lua_State *L, struct hive *h, struct worker *w)
{
	lua_Integer id;
	struct thread_context *ctx;
	int waiting = load(&h->worker_waiting);
	int idle = h->thread_live - load(&h->thread_busy);
	if ((idle - waiting) <= 0 && h->thread_live < h->thread_max) {
		create_thread(h);
		if (h->thread_live == 0) {
			return luaL_error(L, "failed to create thread");
		}
	}
	id = (lua_Integer)(++h->id);
	w->task_id = id;
	lua_pushvalue(w->L, 1);
	copy_values(L, w->L, 2, lua_gettop(L));
	ctx = h->table[h->round_robin++ % h->thread_live];
	assert(ctx->shutdown == 0);
	pthread_mutex_lock(&ctx->lock);
	*ctx->tail = w;
	ctx->tail = &w->next;
	pthread_cond_signal(&ctx->cond);
	pthread_mutex_unlock(&ctx->lock);
	add(&h->worker_waiting, 1);
	return id;
}

static int llimit(lua_State *L)
{
	struct hive *h;
	h = (struct hive *)(lua_touserdata(L, lua_upvalueindex(UPVAL_HIVE)));
	int min = luaL_checkinteger(L, 1);
	int max = luaL_checkinteger(L, 2);
	luaL_argcheck(L, min <= max, 2, "max must be greater than or equal to min");
	luaL_argcheck(L, max > 0, 2, "max must be positive");
	h->thread_min = min;
	h->thread_max = max;
	return 0;
}

static int try_kill_thread(struct thread_context *ctx, time_t dead_time)
{
	if (acquire(&ctx->status) != THREAD_IDLE) {
		return 0;
	}
	if (ctx->idle_start > dead_time) {
		return 0;
	}
	pthread_mutex_lock(&ctx->lock);
	if (acquire(&ctx->status) == THREAD_IDLE && ctx->idle_start < dead_time && ctx->head == NULL) {
		ctx->shutdown = 1;
		pthread_cond_signal(&ctx->cond);
	}
	pthread_mutex_unlock(&ctx->lock);
	return ctx->shutdown;
}

static int lprune(lua_State *L)
{
	struct hive *h;
	int n = 0;
	int max_kill = 0;
	time_t dead_time;
	struct thread_context **tail;
	h = (struct hive *)(lua_touserdata(L, lua_upvalueindex(UPVAL_HIVE)));
	if (h->thread_live < h->thread_min) {
		return 0;
	}
	tail = try_join_dead_threads(h, 0);
	// Step 2: try kill idle threads
	max_kill = h->thread_live - h->thread_min;
	dead_time = time(NULL) - IDLE_TIMEOUT;
	for (int i = 0; i < h->thread_live; i++) {
		struct thread_context *ctx = h->table[i];
		if (max_kill > 0 && try_kill_thread(ctx, dead_time)) {
			max_kill--;
			*tail = ctx;
			tail = &ctx->next;
		} else {
			h->table[n++] = ctx;
		}
	}
	for (int i = n; i < h->thread_live; i++) {
		h->table[i] = NULL;
	}
	*tail = NULL;
	h->thread_live = n;
	return 0;
}

static int lspawn(lua_State *L)
{
	const char *code = luaL_checkstring(L, 1);
	struct worker *w = (struct worker *)lua_newuserdatauv(L, sizeof(*w), 0);
	w->L = NULL;
	w->next = NULL;
	w->task_id = 0;
	w->pcall_status = 0;
	if (luaL_newmetatable(L, MT_WORKER)) {
		lua_pushstring(L, "__gc");
		lua_pushcfunction(L, l_worker_gc);
		lua_settable(L, -3);
	}
	lua_setmetatable(L, -2);
	w->L = luaL_newstate();
	luaL_openlibs(w->L);

	if (luaL_loadstring(w->L, code) != LUA_OK) {
		copy_value(w->L, L, -1);
		return lua_error(L);
	}

	int n = lua_gettop(L);
	copy_values(L, w->L, 2, n);

	if (lua_pcall(w->L, n - 1, 1, 0) != LUA_OK) {
		copy_value(w->L, L, -1);
		return lua_error(L);
	}
	if (lua_gettop(w->L) != 1 || lua_type(w->L, 1) != LUA_TFUNCTION) {
		return luaL_error(L, "chunk code must return a function");
	}
	return 1;
}

static int lpush(lua_State *L)
{
	struct hive *h = (struct hive *)(lua_touserdata(L, lua_upvalueindex(UPVAL_HIVE)));
	struct worker *w = (struct worker *)luaL_checkudata(L, 1, MT_WORKER);
	luaL_argcheck(L, w->task_id == 0, 1, "worker is working");
	if (lua_gettop(w->L) != 1) {
		return luaL_error(L, "worker stack is messed up");
	}
	lua_Integer id = push_into_hive(L, h, w);
	lua_pushinteger(L, id);
	return 1;
}

static int lthreads(lua_State *L)
{
	struct hive *h = (struct hive *)(lua_touserdata(L, lua_upvalueindex(UPVAL_HIVE)));
	lua_pushinteger(L, h->thread_live);
	return 1;
}

int luaopen_core_hive_c(lua_State *L) {
	const struct luaL_Reg tbl[] = {
		{"limit", llimit},
		{"prune", lprune},
		{"spawn", lspawn},
		{"push", lpush},
		{"threads", lthreads},
		{NULL, NULL}
	};
	MSG_TYPE_HIVE_DONE = message_new_type();
	luaL_newlibtable(L, tbl);
	new_hive(L);
	luaL_setfuncs(L, tbl, 1);
	lua_pushinteger(L, MSG_TYPE_HIVE_DONE);
	lua_setfield(L, -2, "DONE");
	return 1;
}
