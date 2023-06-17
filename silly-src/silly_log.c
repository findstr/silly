#include <stdio.h>
#include <stdarg.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/time.h>
#include "silly.h"
#include "compiler.h"
#include "silly_timer.h"
#include "silly_log.h"

static char pid[16];
static int pidlen;
static enum silly_log_level log_level;
static __thread struct {
	char buf[64];
	char *sstr;
	char *mstr;
	char *term;
	time_t sec;
	time_t msec;
} head_cache = {
	"",
	NULL,
	NULL,
	NULL,
	0,
	0,
};

static char level_names[] = {
	'D',
	'I',
	'W',
	'E',
};

void
silly_log_init()
{
	pidlen = snprintf(pid, sizeof(pid), "%d ", getpid());
	log_level = SILLY_LOG_INFO;
	return ;
}

void
silly_log_setlevel(enum silly_log_level level)
{
	if (level >= sizeof(level_names) / sizeof(level_names[0])) {
		//TODO:
		return;
	}
	log_level = level;
}

enum silly_log_level
silly_log_getlevel()
{
	return log_level;
}

static inline void
fmttime()
{
	uint64_t now = silly_timer_now();
	time_t sec = now / 1000;
	int ms = now % 1000;
	if (head_cache.sstr == NULL) {
		memcpy(head_cache.buf, pid, pidlen);
		head_cache.sstr = head_cache.buf + pidlen;
	}
	if (sec != head_cache.sec) {
		int len;
		struct tm tm;
		char *end = &head_cache.buf[sizeof(head_cache.buf)];
		head_cache.sec= sec;
		localtime_r(&sec, &tm);
		len = strftime(
			head_cache.sstr,
			end - head_cache.sstr,
			"%Y-%m-%d %H:%M:%S", &tm
		);
		head_cache.mstr = head_cache.sstr + len;
	}
	if (ms != head_cache.msec) {
		int len;
		char *end = &head_cache.buf[sizeof(head_cache.buf)];
		head_cache.msec = ms;
		//NOTE: the ms is less than 100,
		//and the head_cache.str is ensure enough
		//so use sprintf instead of snprintf
		len = snprintf(
			head_cache.mstr,
			end - head_cache.mstr,
			".%03d ", ms
		);
		head_cache.term = head_cache.mstr + len;
	}
	return;
}


void
silly_log_head(enum silly_log_level level)
{
	fmttime();
	head_cache.term[0] = level_names[level];
	head_cache.term[1] = ' ';
	fwrite(head_cache.buf, sizeof(char),
		head_cache.term + 2 - head_cache.buf, stdout);
}

void
silly_log_fmt(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	vfprintf(stdout, fmt, ap);
	va_end(ap);
	return ;
}

void
silly_log_append(const char *str, size_t sz)
{
	fwrite(str, sizeof(char), sz, stdout);
}

void
silly_log_flush()
{
	fflush(stdout);
}

