#ifndef _TIMER_H
#define _TIMER_H

#include <stdint.h>

void silly_timer_init();
void silly_timer_exit();
void silly_timer_dispatch();
uint32_t silly_timer_timeout(uint32_t expire);
uint32_t silly_timer_now();

#endif


