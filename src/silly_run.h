#ifndef _SILLY_RUN_H
#define _SILLY_RUN_H

struct silly_config;
int silly_run(const struct boot_args *config);
void silly_shutdown(int status);

#endif
