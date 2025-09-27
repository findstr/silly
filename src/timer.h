#ifndef _TIMER_H
#define _TIMER_H

#include <time.h>
#include <stdint.h>

void timer_init();
void timer_exit();
void timer_update();
uint64_t timer_after(uint32_t expire, uint32_t ud);
int timer_cancel(uint64_t session, uint32_t *ud);
uint64_t timer_now();
uint64_t timer_monotonic();
uint32_t timer_info(uint32_t *expired);

#endif
