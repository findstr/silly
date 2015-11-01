#include <stdint.h>
#include <stdlib.h>
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

#define UV_PROFILE      1
#define UV_BK_RESUME    2
#define UV_BK_YIELD     3

#define UV_CO           2


static uint32_t
_getms()
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
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &tp);
        ms = tp.tv_sec * 1000;
        ms += tp.tv_nsec / 1000000;
#endif
        return ms;
}

static void
_hook(lua_State *L, lua_Debug *ar);

static int
_check_thread_exist(lua_State *L, int new)
{
        int exist;
        lua_pushlightuserdata(L, _hook);
        lua_rawget(L, LUA_REGISTRYINDEX);
        lua_pushthread(L);
        lua_rawget(L, -2);
        if (lua_isnil(L, -1))
                exist = 0;
        else
                exist = 1;
        if ((exist == 0) && (new == 1)) {
                lua_pop(L, 1);
                
                lua_pushthread(L);
                lua_newtable(L);

                lua_newtable(L);
                lua_setfield(L, -2, "current_time");

                lua_newtable(L);
                lua_setfield(L, -2, "total_time");

                lua_newtable(L);
                lua_setfield(L, -2, "call_times");

                lua_newtable(L);
                lua_setfield(L, -2, "debug_info");

                lua_rawset(L, -3);

        }

        lua_pop(L, 2);

        return exist;
}

static __inline void
_getupvalue(lua_State *L, const char *name)
{
        lua_pushlightuserdata(L, _hook);
        lua_rawget(L, LUA_REGISTRYINDEX);
        lua_pushthread(L);
        lua_rawget(L, -2);

        lua_getfield(L, -1, name);

        lua_insert(L, -3);
        lua_settop(L, -3);

        return ;
}

static void
_fill_debug_info(lua_State *L, const char *uid, lua_Debug *ar)
{
        _getupvalue(L, "debug_info");

        lua_pushstring(L, uid);
        lua_newtable(L);

        lua_pushstring(L, "name");
        lua_pushstring(L, ar->name);
        lua_rawset(L, -3);

        lua_pushstring(L, "what");
        lua_pushstring(L, ar->what);
        lua_rawset(L, -3);

        lua_pushstring(L, "source");
        lua_pushstring(L, ar->source);
        lua_rawset(L, -3);

        lua_pushstring(L, "linedefined");
        lua_pushinteger(L, ar->linedefined);
        lua_rawset(L, -3);

        lua_rawset(L, -3);

        lua_pop(L, 1);

        return ;
}

static int
_get_uid(char uid[256], lua_Debug *ar)
{
        if (strcmp(ar->what, "Lua") == 0) {
                snprintf(uid, 256, "%s:%d", ar->source, ar->linedefined);
                return 0;
        }

        return -1;
}

/*
static int
_exist_current_time(lua_State *L, const char *uid)
{
        int ret = 0;

        if (_check_thread_exist(L, 0) == 0)
                return 0;

        _getupvalue(L, "current_time");
        lua_getfield(L, -1, uid);
        if (lua_isnil(L, -1))
                ret = 0;
        else
                ret = 1;

        lua_pop(L, 2);
 
        return ret;
}
*/

static void
_update_current_time(lua_State *L, const char *uid, lua_Integer ms)
{
        _getupvalue(L, "current_time");
        lua_pushstring(L, uid);
        lua_pushinteger(L, ms);
        lua_rawset(L, -3);
        lua_pop(L, 1);
 
        return ;
}

static void
_call_hook(lua_State *L, lua_Debug *ar)
{
        char uid[256];
        lua_Integer ms = _getms();
        lua_getinfo(L, "Sn", ar);

        if (_get_uid(uid, ar))
                return ;

        //printf("call hook:%s, current_time:%lld\n", uid, ms);
        //call time
        _check_thread_exist(L, 1);
        _update_current_time(L, uid, ms);
        
        //total time
        _getupvalue(L, "total_time");
        lua_pushstring(L, uid);
        lua_rawget(L, -2);
        if (lua_isnil(L, -1)) { //new function
                lua_pop(L, 1);
                //total time
                lua_pushstring(L, uid);
                lua_pushinteger(L, 0);
                lua_rawset(L, -3);
                lua_pop(L, 1);
                
                //call times
                _getupvalue(L, "call_times");
                lua_pushstring(L, uid);
                lua_pushinteger(L, 1);
                lua_rawset(L, -3);
                lua_pop(L, 1);

                //debug info
                _fill_debug_info(L, uid, ar);
        } else {
                int times;
                //call times
                _getupvalue(L, "call_times");
                lua_pushstring(L, uid);
                lua_rawget(L, -2);
                times = luaL_checkinteger(L, -1);
                lua_pop(L, 1);

                times += 1;

                lua_pushstring(L, uid);
                lua_pushinteger(L, times);
                lua_rawset(L, -3);
                lua_pop(L, 1);
        }

        return ;
}

static void
_update_total_time(lua_State *L, const char *uid, lua_Integer ms)
{
        lua_Integer start = 0;
        lua_Integer total;

        _getupvalue(L, "current_time");
        lua_pushstring(L, uid);
        lua_rawget(L, -2);
        start = luaL_checkinteger(L, -1);
        lua_pop(L, 2);
        
        ms = ms - start;

        //total time
        _getupvalue(L, "total_time");
        lua_pushstring(L, uid);
        lua_rawget(L, -2);
        total = luaL_checkinteger(L, -1);
        lua_pop(L, 1);

        total += ms;
        
        lua_pushstring(L, uid);
        lua_pushinteger(L, total);
        lua_rawset(L, -3);
        lua_pop(L, 1);

        return ;
}

static void
_ret_hook(lua_State *L, lua_Debug *ar)
{
        char uid[256];
        lua_Integer ms = _getms();

        lua_getinfo(L, "S", ar);

        if (_get_uid(uid, ar))
                return ;

        if (_check_thread_exist(L, 0))
                _update_total_time(L, uid, ms);

        return ;
}

static void
_hook(lua_State *L, lua_Debug *ar)
{
        if (ar->event == LUA_HOOKCALL)
                _call_hook(L, ar);
        else if (ar->event == LUA_HOOKRET)
                _ret_hook(L, ar);

        return ;
}

/*
static int
_yield(lua_State *L)
{
        int i;
        char uid[256];
        lua_Integer ms = _getms();
        lua_Debug ar;

        for (i = 1; lua_getstack(L, i, &ar); i++) {
                lua_getinfo(L, "S", &ar);
                if (_get_uid(uid, &ar))
                        continue;
                if (_exist_current_time(L, uid)) {
                        _update_total_time(L, uid, ms);
                }
        }

        lua_CFunction co_yield = lua_tocfunction(L, lua_upvalueindex(UV_CO));
        if (co_yield == NULL)
                return luaL_error(L, "profile::_yield can't find the yield function");

        return co_yield(L);
}

static int
_resume(lua_State *L)
{
        int i;
        char uid[256];
        lua_Integer ms = _getms();
        lua_Debug ar;

        for (i = 1; lua_getstack(L, i, &ar); i++) {
                lua_getinfo(L, "S", &ar);
                if (_get_uid(uid, &ar))
                        continue;
                if (_exist_current_time(L, uid))
                        _update_current_time(L, uid, ms);
        }

        lua_CFunction co_resume = lua_tocfunction(L, lua_upvalueindex(UV_CO));
        if (co_resume == NULL)
                return luaL_error(L, "profile::_yield can't find the yield function");

        return co_resume(L);
}

*/

static int
_start(lua_State *L)
{
        lua_sethook(L, _hook, LUA_MASKCALL | LUA_MASKRET, 0);

        lua_newtable(L);
        lua_replace(L, lua_upvalueindex(UV_PROFILE));
/*
        lua_getglobal(L, "coroutine");
        int coindex = lua_gettop(L);

        lua_pushvalue(L, lua_upvalueindex(UV_PROFILE));
        lua_getfield(L, coindex, "resume");
        lua_CFunction co_resume = lua_tocfunction(L, -1);
        if (co_resume == NULL)
                return luaL_error(L, "can't get coroutine.resume");
        
        lua_pushvalue(L, lua_upvalueindex(UV_PROFILE));
        lua_getfield(L, coindex, "yield");
        lua_CFunction co_yield = lua_tocfunction(L, -1);
        if (co_yield == NULL)
                return luaL_error(L, "can't get coroutine.yield");

        lua_pushcclosure(L, _yield, 2);
        lua_setfield(L, coindex, "yield");
        
        lua_pushcclosure(L, _resume, 2);
        lua_setfield(L, coindex, "resume");
*/        
        return 0;
}

static int
_stop(lua_State *L)
{
        lua_sethook(L, NULL, 0, 0);

        /*
        lua_getglobal(L, "coroutine");
 
        lua_CFunction co_resume = lua_tocfunction(L, lua_upvalueindex(UV_BK_RESUME));
        lua_pushcfunction(L, co_resume);
        lua_setfield(L, -2, "resume");

        lua_CFunction co_yield = lua_tocfunction(L, lua_upvalueindex(UV_BK_YIELD));
        lua_pushcfunction(L, co_yield);
        lua_setfield(L, -2, "yield");

        lua_pop(L, 1);
        */

        return 0;
}


static int
_report(lua_State *L)
{
        lua_pushlightuserdata(L, _hook);
        lua_rawget(L, LUA_REGISTRYINDEX);

        return 1;
}

int luaopen_profile(lua_State *L)
{
        luaL_Reg tbl[] = {
                {"start", _start},
                {"stop", _stop},
                {"report", _report},
                {NULL, NULL},
        };

        luaL_checkversion(L);


        //lua_getglobal(L, "coroutine");
        //int coindex = lua_gettop(L);

        luaL_newlibtable(L, tbl);

        lua_newtable(L);
        //metatable
        lua_newtable(L);
        lua_pushliteral(L, "k");
        lua_setfield(L, -2, "__mode");
        lua_setmetatable(L, -2);

        lua_pushlightuserdata(L, _hook);
        lua_pushvalue(L, -2);
        lua_rawset(L, LUA_REGISTRYINDEX);

        /*
        lua_getfield(L, coindex, "resume");
        lua_CFunction co_resume = lua_tocfunction(L, -1);
        if (co_resume == NULL)
                return luaL_error(L, "can't get coroutine.resume");
        
        lua_getfield(L, coindex, "yield");
        lua_CFunction co_yield = lua_tocfunction(L, -1);
        if (co_yield == NULL)
                return luaL_error(L, "can't get coroutine.yield");
        */

        luaL_setfuncs(L, tbl, 1);

        return 1;
}



