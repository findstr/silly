#ifndef	_SILLY_LOG_H
#define	_SILLY_LOG_H

#define LOG_MAX_LEN	(1024)

void silly_log_start();
void silly_log_raw(const char *fmt, ...);
void silly_log(const char *fmt, ...);

#endif

