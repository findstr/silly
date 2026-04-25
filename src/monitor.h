#ifndef _MONITOR_H
#define _MONITOR_H

#include <stdarg.h>

void monitor_init();
void monitor_check();

#ifdef SILLY_TEST
void monitor_debug_ctrl(const char *cmd, va_list ap);
int monitor_is_paused(void);
#endif

#endif
