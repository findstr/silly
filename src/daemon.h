#ifndef _DAEMON_H
#define _DAEMON_H

#include "args.h"

void daemon_start(const struct boot_args *conf);
void daemon_stop(const struct boot_args *conf);

#endif
