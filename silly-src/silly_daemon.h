#ifndef _SILLY_DAEMON_H
#define _SILLY_DAEMON_H

void silly_daemon_start(const struct silly_config *conf);
void silly_daemon_sigusr1(const struct silly_config *conf);
void silly_daemon_stop(const struct silly_config *conf);


#endif

