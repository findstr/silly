#ifndef _TIMER_H
#define _TIMER_H

#include <stdint.h>

void silly_timer_init();
void silly_timer_exit();
void silly_timer_update();
uint64_t silly_timer_timeout(uint32_t expire, uint32_t ud);
int silly_timer_cancel(uint64_t session, uint32_t *ud);
uint64_t silly_timer_now();
time_t silly_timer_nowsec();
uint64_t silly_timer_monotonic();
time_t silly_timer_monotonicsec();
uint32_t silly_timer_info(uint32_t *expired);

#endif
