#ifndef	_SILLY_LOG_H
#define	_SILLY_LOG_H

#define silly_log_str(literal)	silly_log_lstr(literal, sizeof(literal) - 1)

void silly_log_start();
void silly_log_raw(const char *fmt, ...);
void silly_log_lstr(const char *str, size_t sz);
void silly_log(const char *fmt, ...);

#endif

