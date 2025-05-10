#ifndef _SILLY_CONF_H
#define _SILLY_CONF_H

#define STR(s) __STR(s)
#define __STR(s) #s

#define TRACE_WORKER_ID (0)
#define TRACE_TIMER_ID (1)
#define TRACE_SOCKET_ID (2)
#define TRACE_MONITOR_ID (3)

#ifdef __WIN32
#define LUA_LIB_SUFFIX ".dll"
#else
#define LUA_LIB_SUFFIX ".so"
#endif

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
#ifndef SOCKET_MAX_EXP
#define SOCKET_MAX_EXP (16)
#endif

#ifndef TCP_READ_BUF_SIZE
#define TCP_READ_BUF_SIZE (4096)
#endif

#ifndef TIMER_RESOLUTION
#define TIMER_RESOLUTION (10) //ms
#endif

#ifndef TIMER_ACCURACY
#define TIMER_ACCURACY (50) //ms
#endif

#ifndef TIMER_DELAY_WARNING
#define TIMER_DELAY_WARNING (10 * TIMER_ACCURACY) //ms
#endif

#ifndef MONITOR_MSG_SLOW_TIME
#define MONITOR_MSG_SLOW_TIME (1000) //ms
#endif

#ifndef LOG_BUF_SIZE
#define LOG_BUF_SIZE (4 * 1024)
#endif

#ifndef LOG_DISABLE_FILE_LINE
#define LOG_ENABLE_FILE_LINE
#endif

#endif
