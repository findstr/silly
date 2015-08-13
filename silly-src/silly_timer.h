#ifndef _TIMER_H
#define _TIMER_H

#include <stdint.h>

int timer_init();
void timer_exit();

int timer_add(int time, int workid, uintptr_t handle, uintptr_t session);

int timer_dispatch();


#endif


