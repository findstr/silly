#ifndef _SILLY_CONF_H
#define _SILLY_CONF_H

//platform related

#ifdef __linux__

#define USE_ACCEPT4
#define _GNU_SOURCE

#define USE_SPINLOCK
#define USE_CPU_AFFINITY

#endif

#define LUA_GC_INC 0
#define LUA_GC_GEN 1
#define LUA_GC_MODE LUA_GC_GEN

#if LUA_GC_MODE == LUA_GC_INC
#define LUA_GC_STEP (100) //KiB
#endif

//(1 << 16) = 65536
#define SOCKET_MAX_EXP (16)
#define TIMER_RESOLUTION (10)                     //ms
#define TIMER_ACCURACY (50)                       //ms
#define TIMER_DELAY_WARNING (10 * TIMER_ACCURACY) //ms
#define MONITOR_MSG_SLOW_TIME (1000)              //ms

#define STR(s) __STR(s)
#define __STR(s) #s

#define LOG_BUF_SIZE (4 * 1024)
#define LOG_ENABLE_FILE_LINE 1

#define TRACE_WORKER_ID (0)
#define TRACE_TIMER_ID (1)
#define TRACE_SOCKET_ID (2)
#define TRACE_MONITOR_ID (3)

#ifdef __WIN32
#define LUA_LIB_SUFFIX ".dll"
#else
#define LUA_LIB_SUFFIX ".so"
#endif

#endif
