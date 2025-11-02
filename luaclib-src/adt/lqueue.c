#include <lua.h>
#include <lauxlib.h>
#include <string.h>
#include <stdint.h>
#include "silly.h"
#include "idpool.h"
#include "lassert.h"

struct queue {
	void *meta;
	struct id_pool idx;
	int readi;      // Next read position
	int writei;     // Next write position
	int bufcap;     // Buffer capacity
	int *buf;  	// Array of ref IDs
};

#define METANAME "silly.adt.queue"
static const int INITIAL_CAP = 8;

static inline int qsize(struct queue *q)
{
	return q->writei - q->readi;
}

static void expand(lua_State *L, struct queue *q, int need)
{
	int newcap = q->bufcap;
	if (newcap == 0)
		newcap = INITIAL_CAP;
	luaL_assert(L, need < INT_MAX / 2, "queue capacity overflow");
	while (newcap < need) {
		newcap *= 2;
	}
	int *newbuf = (int *)silly_realloc(q->buf, newcap * sizeof(*newbuf));
	if (unlikely(newbuf == NULL))
		luaL_error(L, "queue expansion failed");
	q->buf = newbuf;
	q->bufcap = newcap;
}

static void compact(struct queue *q)
{
	int size = qsize(q);
	if (size > 0 && q->readi > 0) {
		memmove(q->buf, q->buf + q->readi, size * sizeof(int));
	}
	q->readi = 0;
	q->writei = size;
}

static int lnew(lua_State *L);

static inline struct queue *check_queue(lua_State *L, int index)
{
	struct queue *q = (struct queue *)lua_touserdata(L, index);
	if (unlikely(q == NULL || q->meta != (void *)&lnew)) {
		luaL_typeerror(L, index, METANAME);
	}
	return q;
}

// queue.new() -> queue
static int lnew(lua_State *L)
{
	struct queue *q = (struct queue *)lua_newuserdatauv(L, sizeof(*q), 1);
	luaL_getmetatable(L, METANAME);
	lua_setmetatable(L, -2);
	q->readi = 0;
	q->writei = 0;
	q->buf = NULL;
	q->bufcap = 0;
	q->meta = (void *)&lnew;
	id_pool_init(&q->idx);
	lua_newtable(L);
	lua_setiuservalue(L, 1, 1);
	return 1;
}

// queue:push(value)
static int lappend(lua_State *L)
{
	int ref;
	struct queue *q = check_queue(L, 1);
	luaL_assert(L, q->writei < INT_MAX, "queue write index overflow");
	if (q->writei >= q->bufcap && q->readi > 0) {
		compact(q);
	}
	if (q->writei >= q->bufcap) {
		expand(L, q, q->writei + 1);
	}
	ref = id_pool_alloc(&q->idx);
	lua_getiuservalue(L, 1, 1);
	lua_pushvalue(L, 2);
	lua_seti(L, -2, ref);
	lua_pop(L, 1);
	q->buf[q->writei++] = ref;
	return 0;
}

// queue:pop() -> value or nil
static int lpop(lua_State *L)
{
	int ok;
	struct queue *q = check_queue(L, 1);
	if (q->readi >= q->writei) {
		lua_pushnil(L);
		return 1;
	}
	int ref = q->buf[q->readi++];
	lua_getiuservalue(L, 1, 1);   // Stack: [table]
	lua_geti(L, -1, ref);      // Stack: [table, object]
	lua_pushnil(L);               // Stack: [table, object, nil]
	lua_seti(L, -3, ref);      // table[ref] = nil, Stack: [table, object]
	ok = id_pool_free(&q->idx, ref);
	if (unlikely(ok != 0))
		luaL_error(L, "queue corrupted: invalid reference id");
	lua_replace(L, -2);            // Stack: [object]
	return 1;
}

// queue:size() -> integer
static int lsize(lua_State *L)
{
	struct queue *q = check_queue(L, 1);
	lua_pushinteger(L, qsize(q));
	return 1;
}

// queue:clear() - Clear all items and free references
static int lclear(lua_State *L)
{
	struct queue *q = check_queue(L, 1);
	if (q->readi < q->writei) {
		lua_getiuservalue(L, 1, 1);  // Stack: [table]
		for (int i = q->readi; i < q->writei; i++) {
			int ref = q->buf[i];
			lua_pushnil(L);
			lua_seti(L, -2, ref);  // table[ref] = nil
			id_pool_free(&q->idx, ref);
		}
		lua_pop(L, 1);  // Pop table
	}
	q->readi = 0;
	q->writei = 0;
	return 0;
}

static int lgc(lua_State *L)
{
	struct queue *q = check_queue(L, 1);
	if (q->buf) {
		silly_free(q->buf);
		q->buf = NULL;
	}
	id_pool_destroy(&q->idx);
	q->meta = NULL;
	return 0;
}

SILLY_MOD_API int luaopen_silly_adt_queue(lua_State *L)
{
	luaL_Reg methods[] = {
		{"new",  lnew},
		{"push", lappend},
		{"pop", lpop},
		{"size", lsize},
		{"clear", lclear},
		{NULL, NULL}
	};
	luaL_newlib(L, methods);
	luaL_newmetatable(L, METANAME);
	lua_pushvalue(L, -2);
	lua_setfield(L, -2, "__index");
	lua_pushcfunction(L, lgc);
	lua_setfield(L, -2, "__gc");
	lua_pop(L, 1);
	return 1;
}
