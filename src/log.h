#ifndef _LOG_H
#define _LOG_H

#include <stddef.h>
#include "silly.h"
#include "args.h"

void log_init(const struct boot_args *config);
void log_open_file(const char *path);
void log_set_level(enum silly_log_level level);
enum silly_log_level log_get_level();
void log_head(enum silly_log_level level);
void log_vfmt(const char *fmt, va_list ap);
void log_fmt(const char *fmt, ...);
void log_append(const char *str, size_t sz);
void log_flush();

#define log_visible(level) (level >= log_get_level())
#define log_(level, ...)                   \
	do {                               \
		if (!log_visible(level)) { \
			break;             \
		}                          \
		log_head(level);           \
		log_fmt(__VA_ARGS__);      \
	} while (0)

#define log_debug(...) log_(SILLY_LOG_DEBUG, __VA_ARGS__)
#define log_info(...) log_(SILLY_LOG_INFO, __VA_ARGS__)
#define log_warn(...) log_(SILLY_LOG_WARN, __VA_ARGS__)
#define log_error(...) log_(SILLY_LOG_ERROR, __VA_ARGS__)

#endif
