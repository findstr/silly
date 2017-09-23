#ifndef _SILLY_CONF_H
#define _SILLY_CONF_H

#define USE_JEMALLOC

#ifdef __linux__

#define USE_ACCEPT4
#define _GNU_SOURCE

#define USE_SPINLOCK
#define USE_CPU_AFFINITY

#endif

#define TIMER_RESOLUTION	(10)

#endif
