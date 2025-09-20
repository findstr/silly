#ifndef _RUN_H
#define _RUN_H

struct silly_config;
int silly_run(const struct boot_args *config);
void silly_shutdown(int status);

#endif
