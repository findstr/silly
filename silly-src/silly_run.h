#ifndef _SILLY_RUN_H
#define _SILLY_RUN_H

struct silly_config;
int silly_run(const struct silly_config *config);
void silly_exit(int status);

#endif

