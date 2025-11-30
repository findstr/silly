#ifndef _TIMER_H
#define _TIMER_H
#include "silly.h"
#include <time.h>
#include <stdint.h>

void timer_init();
void timer_exit();
void timer_update();
uint64_t timer_after(uint32_t expire);
int timer_cancel(uint64_t session);
uint64_t timer_now();
uint64_t timer_monotonic();
void timer_stat(struct silly_timerstat *stat);

#endif
