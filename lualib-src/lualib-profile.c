#include <stdlib.h>
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>
#include <time.h>
#ifdef __macosx__
#include <mach/mach_init.h>
#include <mach/thread_act.h>
#include <mach/mach_port.h>
#endif


static uint32_t
_getms()
{
        uint32_t ms;
#ifdef __macosx__
        mach_msg_type_number_t count = THREAD_BASIC_INFO_COUNT;
        struct thread_basic_info info;
        
        kern_return_t kr = thread_info(mach_thread_self(), THREAD_BASIC_INFO, (thread_info_t) &info, &count);
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

static int
_start(lua_State *L)
{
        uint32_t ms = _getms();
        lua_pushinteger(L, ms);

        return 1;
}

static int
_stop(lua_State *L)
{
        uint32_t ms = luaL_checkinteger(L, 1);
        lua_pushinteger(L, _getms() - ms);

        return 1;
}

int luaopen_profile(lua_State *L)
{
        luaL_Reg tbl[] = {
                {"start", _start},
                {"stop", _stop},
                {NULL, NULL},
        };


        luaL_newlib(L, tbl);

        return 1;
}



