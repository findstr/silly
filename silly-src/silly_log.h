#ifndef _SILLY_LOG_H
#define _SILLY_LOG_H

struct silly_config;

enum silly_log_level {
	SILLY_LOG_DEBUG = 0,
	SILLY_LOG_INFO = 1,
	SILLY_LOG_WARN = 2,
	SILLY_LOG_ERROR = 3,
};

void silly_log_init();
void silly_log_openfile(const char *path);
void silly_log_setlevel(enum silly_log_level level);
enum silly_log_level silly_log_getlevel();
void silly_log_head(enum silly_log_level level);
void silly_log_fmt(const char *fmt, ...);
void silly_log_append(const char *str, size_t sz);
void silly_log_flush();

#define silly_log_visible(level) (level >= silly_log_getlevel())
#define silly_log_(level, ...)                   \
	do {                                     \
		if (!silly_log_visible(level)) { \
			break;                   \
		}                                \
		silly_log_head(level);           \
		silly_log_fmt(__VA_ARGS__);      \
	} while (0)

#define silly_log_debug(...) silly_log_(SILLY_LOG_DEBUG, __VA_ARGS__)
#define silly_log_info(...) silly_log_(SILLY_LOG_INFO, __VA_ARGS__)
#define silly_log_warn(...) silly_log_(SILLY_LOG_WARN, __VA_ARGS__)
#define silly_log_error(...) silly_log_(SILLY_LOG_ERROR, __VA_ARGS__)

#endif
