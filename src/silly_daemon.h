#ifndef _SILLY_DAEMON_H
#define _SILLY_DAEMON_H

#include "args.h"

void daemon_start(const struct boot_args *conf);
void daemon_stop(const struct boot_args *conf);

#endif
