#ifndef _TIMER_H
#define _TIMER_H

#include <stdint.h>

void silly_timer_init();
void silly_timer_exit();
void silly_timer_update();
uint32_t silly_timer_timeout(uint32_t expire);
uint64_t silly_timer_now();
uint64_t silly_timer_monotonic();
time_t silly_timer_monotonicsec();

#endif


