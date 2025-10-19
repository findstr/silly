#ifndef _SILLY_CONF_H
#define _SILLY_CONF_H

#define STR(s) __STR(s)
#define __STR(s) #s

#ifdef __WIN32
#define LUA_LIB_SUFFIX ".dll"
#else
#define LUA_LIB_SUFFIX ".so"
#endif

#if defined(_WIN32)
#if defined(SILLY_BUILD_SHARED)
#define SILLY_API __declspec(dllimport)
#define SILLY_MOD_API __declspec(dllexport)
#else
#define SILLY_API __declspec(dllexport)
#define SILLY_MOD_API __declspec(dllimport)
#endif
#else
#define SILLY_API __attribute__((visibility("default")))
#define SILLY_MOD_API __attribute__((visibility("default")))
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
#ifndef SOCKET_POOL_EXP
#define SOCKET_POOL_EXP (16)
#endif

#ifndef TCP_READ_BUF_SIZE
#define TCP_READ_BUF_SIZE (2 * 1024 * 1024) //2MB
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

#ifndef PATH_MAX
#define PATH_MAX 256
#endif

#include <stdint.h>

#ifdef __WIN32
#define random() rand()
#define localtime_r(t, tm) localtime_s(tm, t)
#endif

#if defined(__linux__) || defined(__MACH__)
#include <arpa/inet.h>
#elif defined(__WIN32)
#include <ws2tcpip.h>
#else
#error "Unsupported platform"
#endif
#define SILLY_SOCKET_NAMELEN (INET6_ADDRSTRLEN + 8 + 1) //[ipv6]:port

typedef int64_t silly_socket_id_t;

#endif
