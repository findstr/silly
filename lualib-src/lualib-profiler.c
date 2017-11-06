#include <assert.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>
#include <time.h>
#ifdef __macosx__
#include <mach/mach_init.h>
#include <mach/thread_act.h>
#include <mach/task.h>
#include <mach/mach_port.h>
#endif

#define UV_M 1
#define UV_G 2
#define UV_TIME 3
#define UV_CALL 4
#define UV_START 5
#define	UV_COSTAMP 6
#define	UV_COTIME 7

static uint32_t
timestamp()
{
	uint32_t ms;
#ifdef __macosx__
	struct task_thread_times_info info;
	mach_msg_type_number_t count = TASK_THREAD_TIMES_INFO_COUNT;
	kern_return_t kr = task_info(mach_task_self(), TASK_THREAD_TIMES_INFO,
			(task_info_t)&info, &count);
	if (kr != KERN_SUCCESS)
		return 0;
	ms = info.user_time.seconds * 1000;
	ms += info.user_time.microseconds / 1000;
	ms += info.system_time.seconds * 1000;
	ms += info.system_time.microseconds / 1000;
#else
	struct timespec tp;
	clock_gettime(CLOCK_MONOTONIC, &tp);
	ms = tp.tv_sec * 1000;
	ms += tp.tv_nsec / 1000000;
#endif
	return ms;
}

static inline lua_Integer
diff(lua_Integer last, lua_Integer now)
{
	return (uint64_t)now - (uint64_t) last;
}


static inline lua_Integer
gettuv(lua_State *L, int upidx)
{
	lua_Integer v;
	lua_pushthread(L);
	lua_rawget(L, lua_upvalueindex(upidx));
	v = luaL_checkinteger(L, -1);
	lua_pop(L, 1);
	return v;
}

static inline void
settuv(lua_State *L, int t, lua_Integer v)
{
	lua_pushthread(L);
	lua_pushinteger(L, v);
	lua_rawset(L, lua_upvalueindex(t));
	return ;
}

static lua_Integer
coupdate(lua_State *L, lua_Integer stamp)
{
	lua_Integer time;
	lua_Integer last;
	time = gettuv(L, UV_COTIME);
	last = gettuv(L, UV_COSTAMP);
	time += diff(last, stamp);
	settuv(L, UV_COTIME, time);
	settuv(L, UV_COSTAMP, stamp);
	return time;
}

static inline lua_Integer
coinit(lua_State *L, lua_Integer stamp)
{
	lua_Integer time;
	lua_pushthread(L);
	lua_rawget(L, lua_upvalueindex(UV_COTIME));
	if (!lua_isnil(L, -1)) {
		time = coupdate(L, stamp);
	} else {
		time = 1;
		settuv(L, UV_COTIME, 1);
		settuv(L, UV_COSTAMP, stamp);
	}
	lua_pop(L, 1);
	return time;
}

static inline lua_Integer
getkuv(lua_State *L, int k)
{
	lua_Integer v;
	lua_pushvalue(L, lua_upvalueindex(k));
	lua_rawget(L, -2);
	v = luaL_checkinteger(L, -1);
	lua_pop(L, 1);
	return v;
}

static inline void
setkuv(lua_State *L, int k, lua_Integer v)
{
	lua_pushvalue(L, lua_upvalueindex(k));
	lua_pushinteger(L, v);
	lua_rawset(L, -3);
	return ;
}

static inline void
setkt(lua_State *L, lua_Integer v)
{
	lua_pushthread(L);
	lua_pushinteger(L, v);
	lua_rawset(L, -3);
	return ;
}

static inline lua_Integer
getkt(lua_State *L)
{
	lua_Integer v;
	lua_pushthread(L);
	lua_rawget(L, -2);
	v = luaL_checkinteger(L, -1);
	lua_pop(L, 1);
	return v;
}

static inline lua_Integer
fetchsetkt(lua_State *L, lua_Integer v)
{
	lua_Integer res;
	lua_pushthread(L);
	lua_rawget(L, -2);
	if (lua_isnil(L, -1))
		res = 0;
	else
		res = luaL_checkinteger(L, -1);
	lua_pop(L, 1);
	setkt(L, v);
	return res;
}

static int
lstart(lua_State *L)
{
	lua_Integer stamp = timestamp();
	stamp = coinit(L, stamp);
	lua_pushvalue(L, 1);
	lua_rawget(L, lua_upvalueindex(UV_G));
	if (lua_isnil(L, -1)) {
		lua_pushvalue(L, 1); //push name
		lua_newtable(L);
		lua_pushvalue(L, lua_upvalueindex(UV_M));
		lua_setmetatable(L, -2);

		setkuv(L, UV_TIME, 0);
		setkuv(L, UV_CALL, 1);
		setkt(L, stamp);
		//set to global
		lua_rawset(L, lua_upvalueindex(UV_G));
	} else {
		lua_Integer last;
		lua_Integer call;
		last = fetchsetkt(L, stamp);
		if (last != 0) {
			return luaL_error(L,
					"profiler.start and profiler.stop should in pairs:%d",
					last);
		}
		//update 'call'
		call = getkuv(L, UV_CALL);
		setkuv(L, UV_CALL, call + 1);
	}
	lua_pop(L, 1);
	return 0;
}

static int
lstop(lua_State *L)
{
	lua_Integer now;
	lua_Integer time;
	lua_Integer stamp;
	now = timestamp();
	now = coupdate(L, now);
	lua_pushvalue(L, -1);	//name
	lua_rawget(L, lua_upvalueindex(UV_G));
	if (lua_isnil(L, -1))
		return luaL_error(L, "profiler.stop incorrect stop:%s", luaL_checkstring(L, 1));
	//update
	stamp = getkt(L);
	if (stamp == 0)
		return luaL_error(L, "number of profiler.start and profiler.stop don't equal");
	time = getkuv(L, UV_TIME);
	time += now - stamp;
	setkuv(L, UV_TIME, time);

	setkt(L, 0);

	lua_pop(L, 1);
	return 0;
}

static int
lyield(lua_State *L)
{
	lua_Integer stamp;
	stamp = timestamp();
	lua_pushthread(L);
	lua_rawget(L, lua_upvalueindex(UV_COTIME));
	if (!lua_isnil(L, -1))
		stamp = coupdate(L, stamp);
	lua_pop(L, 1);
	return 0;
}


static int
lresume(lua_State *L)
{
	lua_Integer stamp ;
	stamp = timestamp();

	lua_pushvalue(L, 1);
	lua_rawget(L, lua_upvalueindex(UV_COSTAMP));
	if (!lua_isnil(L, -1)) {
		lua_pushvalue(L, 1);
		lua_pushinteger(L, stamp);
		lua_rawset(L, lua_upvalueindex(UV_COSTAMP));
	}
	lua_pop(L, 1);
	return 0;
}

static int
ldump(lua_State *L)
{
	int n = lua_gettop(L);
	if (n == 0) { //dump all
		lua_pushvalue(L, lua_upvalueindex(UV_G));
	} else {
		assert(n == 1);
		lua_pushvalue(L, -1);
		lua_rawget(L, lua_upvalueindex(UV_G));
	}
	return 1;
}

static inline void
newmetatable(lua_State *L)
{
	lua_newtable(L);
	lua_pushliteral(L, "k");
	lua_setfield(L, -2, "__mode");
	return ;
}

int luaopen_sys_profiler(lua_State *L)
{
	int mi;
	luaL_Reg tbl[] = {
		{"start", lstart},
		{"stop", lstop},
		{"yield", lyield},
		{"resume", lresume},
		{"dump", ldump},
		{NULL, NULL},
	};

	luaL_checkversion(L);
	luaL_newlibtable(L, tbl);

	//UV_M
	newmetatable(L);
	mi = lua_gettop(L);
	//UV_G
	lua_newtable(L);
	lua_pushvalue(L, mi);
	lua_setmetatable(L, -2);
	//UV_TIME
	lua_pushliteral(L, "time");
	//UV_CALL
	lua_pushliteral(L, "call");
	//UV_START
	lua_pushliteral(L, "start");
	//UV_COSTAMP
	lua_newtable(L);
	lua_pushvalue(L, mi);
	lua_setmetatable(L, -2);
	//UV_COTIME
	lua_newtable(L);
	lua_pushvalue(L, mi);
	lua_setmetatable(L, -2);

	luaL_setfuncs(L, tbl, 7);

	return 1;
}

