#ifndef _SILLY_CONF_H
#define _SILLY_CONF_H

#define USE_JEMALLOC

#ifdef __linux__

#define USE_ACCEPT4
#define _GNU_SOURCE

#define USE_SPINLOCK
#define USE_CPU_AFFINITY

#endif

//timer resolution = (1000 / TIMER_RESOLUTION)
#define TIMER_RESOLUTION	(10)
#define TIMER_ACCURACY		(50 * 1000)	//us

#define STR(s) __STR(s)
#define __STR(s) #s

#endif
