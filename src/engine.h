#ifndef _ENGINE_H
#define _ENGINE_H
#include "args.h"

int engine_run(const struct boot_args *config);
void engine_shutdown(int status);

#endif
