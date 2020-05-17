#ifndef _SILLY_CONF_H
#define _SILLY_CONF_H

#define USE_JEMALLOC

#ifdef __linux__

#define USE_ACCEPT4
#define _GNU_SOURCE

#define USE_SPINLOCK
#define USE_CPU_AFFINITY

#endif

//(1 << 16) = 65536
#define SOCKET_MAX_EXP		(16)
#define TIMER_RESOLUTION	(10)			//ms
#define TIMER_ACCURACY		(50)			//ms
#define TIMER_DELAY_WARNING	(10 * TIMER_ACCURACY)	//ms
#define MONITOR_MSG_SLOW_TIME	(1000)			//ms

#define STR(s) __STR(s)
#define __STR(s) #s

#endif
