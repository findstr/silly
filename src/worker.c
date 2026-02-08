#include <assert.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <pthread.h>
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>

#include <stdatomic.h>
#include "silly.h"
#include "args.h"
#include "repl.h"
#include "errnoex.h"
#include "compiler.h"
#include "message.h"
#include "log.h"
#include "mem.h"
#include "queue.h"
#include "monitor.h"
#include "worker.h"
#include "platform.h"

#ifndef max
#define max(a, b) ((a) > (b) ? (a) : (b))
#endif
#define WARNING_THRESHOLD (64)

#define STK_TRACEBACK (1)
#define STK_ERROR_TABLE (2)
#define STK_CALLBACK_TABLE (3)
#define STK_DISPATCH_WAKEUP (4)

struct message_signal {
	struct silly_message hdr;
	int signum;
};

struct worker {
	char **argv;
	int argc;
	uint32_t id;
	pthread_t tid;
	lua_State *L;
	lua_State *running;
	uint32_t sigbits;
	atomic_uint_least32_t process_id;
	atomic_uint_least32_t signal_pending;
	atomic_int_least8_t maybe_endless;
	atomic_int_least8_t openhook;
	lua_Hook oldhook;
	int oldmask;
	int oldcount;
	uint32_t maxmsg;
	struct queue *queue;
	void (*callback)(lua_State *L, struct silly_message *msg);
	struct message_signal sig_msg;
};



struct worker *W;

static void warn_hook(lua_State *L, lua_Debug *ar);

static inline void callback(struct silly_message *sm)
{
	int type, err, args;
	lua_State *L = W->L;
	type = lua_geti(L, STK_CALLBACK_TABLE, sm->type);
	if (unlikely(type != LUA_TFUNCTION)) {
		sm->free(sm);
		log_error("[worker] callback need function "
			  "but got:%s\n",
			  lua_typename(L, type));
		return;
	}
	args = sm->unpack(L, sm);
	/*the first stack slot of main thread is always trace function */
	err = lua_pcall(L, args, 0, STK_TRACEBACK);
	if (unlikely(err != LUA_OK)) {
		log_error("[worker] message:%d callback fail:%d:%s\n", sm->type,
			  err, lua_tostring(L, -1));
		lua_pop(L, 1);
	}
	sm->free(sm);
	lua_pushvalue(W->L, STK_DISPATCH_WAKEUP);
	lua_call(W->L, 0, 0);
}

void worker_push(struct silly_message *msg)
{
	size_t sz;
	sz = queue_push(W->queue, msg);
	if (unlikely(sz > W->maxmsg)) {
		W->maxmsg *= 2;
		log_warn("[worker] may overload, "
			 "message queue length:%zu\n",
			 sz);
	}
}

static int signal_unpack(lua_State *L, struct silly_message *m)
{
	struct message_signal *ms = container_of(m, struct message_signal, hdr);
	lua_pushinteger(L, ms->signum);
	return 1;
}

static void signal_free(void *ptr)
{
	(void)ptr;
}

/*
** Signal handler for user signals and monitor's endless loop detection.
**
** Calling lua_sethook() in a signal handler is safe and officially supported.
** See ldebug.c comment: "This function can be called during a signal, under
** 'reasonable' assumptions. [...] 'hookmask' is an atomic value. We assume
** that pointers are atomic too."
**
** The Lua standalone interpreter (lua.c:laction) uses the same pattern:
** setting a hook from SIGINT handler to interrupt execution.
**
** SIGUSR2 collision handling:
** When monitor detects a potential endless loop, it sets maybe_endless=1 and
** sends SIGUSR2. If a user also watches SIGUSR2 and happens to send one at
** the same time, one of them may be "consumed" by the endless loop detection.
** This is acceptable because:
** 1. The program is stuck in an endless loop - user signals would not be
**    processed timely anyway.
** 2. The monitor's SIGUSR2 prints the loop's callstack, which is helpful
**    for debugging.
** 3. Losing a user signal during an endless loop is expected behavior.
** Note: SIGUSR2 is chosen over SIGUSR1 because SIGUSR1 is commonly used by
** system tools like logrotate for log rotation.
*/
static void signal_handler(int sig)
{
	if (unlikely(sig >= (int)(sizeof(W->sigbits) * 8))) {
		return ;
	}
#if defined(__linux__) || defined(__MACH__)
	/* Check if this SIGUSR2 is from monitor's endless loop detection */
	if (sig == SIGUSR2 && atomic_exchange(&W->maybe_endless, 0)) {
		atomic_store_explicit(&W->openhook, 1, memory_order_relaxed);
		W->oldhook = lua_gethook(W->running);
		W->oldmask = lua_gethookmask(W->running);
		W->oldcount = lua_gethookcount(W->running);
		lua_sethook(W->running, warn_hook,
			    LUA_MASKCALL | LUA_MASKRET | LUA_MASKCOUNT, 1);
		return;
	}
#endif
	atomic_fetch_or(&W->signal_pending, 1U << sig);
}

static void process_pending_signals(void)
{
	uint32_t pending;
	pending = atomic_exchange(&W->signal_pending, 0);
	while (pending) {
		int sig = __builtin_ctz(pending);
		pending &= ~(1U << sig);
		W->sig_msg.signum = sig;
		callback(&W->sig_msg.hdr);
	}
}

void worker_dispatch()
{
	struct silly_message *msg;
	struct silly_message *tmp;
	msg = queue_pop(W->queue);
	atomic_fetch_add_explicit(&W->process_id, 1, memory_order_relaxed);
	if (msg == NULL) {
		process_pending_signals();
		return;
	}
	do {
		do {
			atomic_fetch_add_explicit(&W->process_id, 1,
						  memory_order_relaxed);
			tmp = msg->next;
			callback(msg);
			msg = tmp;
		} while (msg);
		process_pending_signals();
		msg = queue_pop(W->queue);
	} while (msg);
	W->maxmsg = WARNING_THRESHOLD;
	return;
}

uint32_t worker_alloc_id()
{
	uint32_t id = ++W->id;
	if (unlikely(id == 0))
		log_warn("[worker] genid wraps around\n");
	return id;
}

size_t worker_backlog()
{
	size_t size = queue_size(W->queue);
	if (atomic_load(&W->signal_pending))
		size++;
	return size;
}

static inline void new_error_table(lua_State *L)
{
#define def(code, str)           \
	lua_pushliteral(L, str); \
	lua_seti(L, -2, code)
	lua_newtable(L);
	def(EX_ADDRINFO, "getaddrinfo failed");
	def(EX_NOSOCKET, "no free socket");
	def(EX_CLOSING, "socket is closing");
	def(EX_CLOSED, "socket is closed");
	def(EX_EOF, "");
#undef def
	lua_pushvalue(L, -1);
	lua_rawsetp(L, LUA_REGISTRYINDEX, (void *)new_error_table);
}

static inline void new_callback_table(lua_State *L)
{
	lua_newtable(L);
	lua_pushvalue(L, -1);
	lua_rawsetp(L, LUA_REGISTRYINDEX, (void *)new_callback_table);
}

void worker_error_table(lua_State *L)
{
	lua_rawgetp(L, LUA_REGISTRYINDEX, (void *)new_error_table);
}

void worker_push_error(lua_State *L, int stk, int code)
{
	if (code == 0) {
		lua_pushnil(L);
		return;
	}
	if (L == W->L) {
		stk = STK_ERROR_TABLE;
	}
	if (lua_rawgeti(L, stk, code) == LUA_TNIL) {
		lua_pop(L, 1);
		lua_pushstring(L, strerror(code));
		lua_pushvalue(L, -1);
		lua_rawseti(L, stk, code);
	}
}

void worker_callback_table(lua_State *L)
{
	lua_rawgetp(L, LUA_REGISTRYINDEX, (void *)new_callback_table);
}

void worker_reset()
{
	queue_clear(W->queue);
	lua_newtable(W->L);
	lua_pushvalue(W->L, -1);
	lua_replace(W->L, STK_CALLBACK_TABLE);
	lua_rawsetp(W->L, LUA_REGISTRYINDEX, (void *)new_callback_table);
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
		mem_free(ptr);
		return NULL;
	} else {
		return mem_realloc(ptr, nsize);
	}
}

static int ltraceback(lua_State *L)
{
	const char *str = luaL_checkstring(L, 1);
	luaL_traceback(L, L, str, 1);
	return 1;
}

static void require_silly_autoload(lua_State *L)
{
	lua_pushcfunction(L, ltraceback);
	lua_getglobal(L, "require");
	lua_pushstring(L, "silly.internal.autoload");
	if (lua_pcall(L, 1, 0, 1) != LUA_OK) {
		log_error("[worker] require silly.autoload fail,%s\n",
			  lua_tostring(L, -1));
		exit(-1);
	}
	lua_pop(L, 1);
}

static void fetch_silly(lua_State *L, const char *func)
{
	lua_getglobal(L, "require");
	lua_pushstring(L, "silly");
	if (lua_pcall(L, 1, 1, 0) != LUA_OK) {
		log_error("[worker] require silly fail,%s\n",
			  lua_tostring(L, -1));
		exit(-1);
	}
	lua_getfield(L, -1, func);
	lua_remove(L, -2);
}

void worker_start(const struct boot_args *config)
{
	int err;
	int dir_len;
	int lib_len;
	W->tid = pthread_self();
	/* Unblock SIGUSR2 and register handler so this thread can receive
	 * it from monitor for endless loop detection */
	signal_register_usr2(signal_handler);
	lua_State *L = lua_newstate(lua_alloc, NULL, luaL_makeseed(NULL));
	luaL_openlibs(L);
	W->argc = config->argc;
	W->argv = config->argv;
	W->L = L;
	W->running = L;
	lua_gc(L, LUA_GCGEN);
	//set load path
	lib_len = max(sizeof("lualib/?.lua"), sizeof("luaclib/?" LUA_LIB_SUFFIX));
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
	assert(lua_gettop(L) == 0);
	// init permanent table
	lua_pushcfunction(L, ltraceback);
	new_error_table(L);
	new_callback_table(L);
	fetch_silly(L, "_dispatch_wakeup");
	// exec silly._start()
	require_silly_autoload(L);
	fetch_silly(L, "_start");
	if (config->bootstrap[0] != '\0') {
		err = luaL_loadfile(L, config->bootstrap);
		if (unlikely(err)) {
			log_error("[worker] load %s %s\n", config->bootstrap,
				  lua_tostring(L, -1));
			lua_close(L);
			exit(-1);
		}
	} else {
		luaL_loadstring(L, REPL);
	}
	if (unlikely(lua_pcall(L, 1, 0, 1))) {
		log_error("[worker] call %s %s\n", config->bootstrap,
			  lua_tostring(L, -1));
		lua_close(L);
		exit(-1);
	}
	lua_pushvalue(L, STK_DISPATCH_WAKEUP);
	lua_call(L, 0, 0);
	return;
}

void worker_init()
{
	W = (struct worker *)mem_alloc(sizeof(*W));
	memset(W, 0, sizeof(*W));
	W->maxmsg = WARNING_THRESHOLD;
	W->queue = queue_create();
	W->sig_msg.hdr.type = MESSAGE_SIGNAL_FIRE;
	W->sig_msg.hdr.unpack = signal_unpack;
	W->sig_msg.hdr.free = signal_free;
	atomic_init(&W->process_id, 0);
	atomic_init(&W->signal_pending, 0);
	atomic_init(&W->maybe_endless, 0);
	return;
}

char **worker_args(int *argc)
{
	*argc = W->argc;
	return W->argv;
}

void worker_resume(lua_State *L)
{
	assert(L != NULL);
	W->running = L;
}

uint32_t worker_process_id()
{
	return atomic_load_explicit(&W->process_id, memory_order_relaxed);
}

static void warn_hook(lua_State *L, lua_Debug *ar)
{
	(void)ar;
	if (atomic_load(&W->openhook) == 0)
		return;
	int top = lua_gettop(L);
	luaL_traceback(L, L, "maybe in an endless loop.", 1);
	log_warn("[worker] %s\n", lua_tostring(L, -1));
	lua_settop(L, top);
	lua_sethook(L, W->oldhook, W->oldmask, W->oldcount);
	atomic_store_explicit(&W->openhook, 0, memory_order_release);
}

void worker_mark_endless()
{
#if defined(__linux__) || defined(__MACH__)
	atomic_store_explicit(&W->maybe_endless, 1, memory_order_relaxed);
	signal_kill_usr2(W->tid);
#else
	log_warn("[worker] maybe in an endless loop\n");
#endif
}

int worker_signal_watch(int signum)
{
	if (unlikely(signum < 0 || signum >= (int)(sizeof(W->sigbits) * 8))) {
		return EINVAL;
	}
	if ((W->sigbits & (1U << signum)) != 0) {
		return 0;
	}
	if (signal(signum, signal_handler) == SIG_ERR) {
		log_error("signal %d watch fail:%s\n", signum, strerror(errno));
		return errno;
	}
	W->sigbits |= 1U << signum;
	return 0;
}

void worker_exit()
{
	lua_close(W->L); // lua close may call worker_push during gc
	queue_free(W->queue);
	mem_free(W);
}
