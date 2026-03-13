#ifndef _LOG_H
#define _LOG_H

#include <stddef.h>
#include "silly.h"
#include "args.h"

void log_init(const struct boot_args *config);
void log_open_file(const char *path);
void log_set_level(enum silly_log_level level);
enum silly_log_level log_get_level(void);
void log_flush(void);
void log_exit(void);

void log_write_(enum silly_log_level level, const char *msg, size_t len);
void log_writef_(enum silly_log_level level, const char *fmt, ...);
void log_directf_(uint64_t now, enum silly_log_level level, const char *fmt, ...);

#define log_visible(level) ((level) >= log_get_level())

#define log_write(level, msg, len) \
	do { \
		if (!log_visible(level)) \
			break; \
		log_write_(level, msg, len); \
	} while (0)

#define log_writef(level, fmt, ...) \
	do { \
		if (!log_visible(level)) \
			break; \
		log_writef_(level, fmt, ##__VA_ARGS__); \
	} while (0)

#define log_directf(now, level, fmt, ...) \
	do { \
		if (!log_visible(level)) \
			break; \
		log_directf_(now, level, fmt, ##__VA_ARGS__); \
	} while (0)

#define log_(level, ...) log_writef(level, __VA_ARGS__)
#define log_debug(...) log_(SILLY_LOG_DEBUG, __VA_ARGS__)
#define log_info(...) log_(SILLY_LOG_INFO, __VA_ARGS__)
#define log_warn(...) log_(SILLY_LOG_WARN, __VA_ARGS__)
#define log_error(...) log_(SILLY_LOG_ERROR, __VA_ARGS__)

#endif
