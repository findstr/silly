#include <stdio.h>
#include <stdarg.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/time.h>
#include "silly.h"
#include "compiler.h"
#include "silly_timer.h"
#include "silly_trace.h"
#include "silly_log.h"

static char pid[16];
static int pidlen;
static enum silly_log_level log_level;
static __thread struct {
	char buf[64];
	char *sstr;
	char *mstr;
	char *tstr;
	char *term;
	time_t sec;
	time_t msec;
	silly_trace_id_t traceid;
} head_cache = {
	"",
	NULL,
	NULL,
	NULL,
	NULL,
	0,
	0,
	0,
};

static char level_names[] = {
	'D',
	'I',
	'W',
	'E',
};

static char hex[] = {
	'0', '1', '2', '3',
	'4', '5', '6', '7',
	'8', '9', 'a', 'b',
	'c', 'd', 'e', 'f',
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

#define BUILD_PID   (0)
#define BUILD_SEC   (1)
#define BUILD_MSEC  (2)
#define BUILD_TRACE (3)
#define BUILD_NONE  (4)

static inline void
fmttime()
{
	int n;
	char *end;
	struct tm tm;
	uint64_t now = silly_timer_now();
	time_t sec = now / 1000;
	int ms = now % 1000;
	silly_trace_id_t traceid = silly_trace_get();
	int build_step;
	if (head_cache.sstr == NULL) {
		build_step = BUILD_PID;
	} else if (sec != head_cache.sec) {
		build_step = BUILD_SEC;
		head_cache.sec= sec;
	} else if (ms != head_cache.msec) {
		build_step = BUILD_MSEC;
		head_cache.msec = ms;
	} else if (traceid != head_cache.traceid) {
		build_step = BUILD_TRACE;
		head_cache.traceid = traceid;
	} else {
		build_step = BUILD_NONE;
	}
	switch (build_step) {
	case BUILD_PID:
		memcpy(head_cache.buf, pid, pidlen);
		head_cache.sstr = head_cache.buf + pidlen;
		//fallthrough
	case BUILD_SEC:
		end = &head_cache.buf[sizeof(head_cache.buf)];
		localtime_r(&sec, &tm);
		n = strftime(
			head_cache.sstr,
			end - head_cache.sstr,
			"%Y-%m-%d %H:%M:%S", &tm
		);
		head_cache.mstr = head_cache.sstr + n;
		//fallthrough
	case BUILD_MSEC:
		end = &head_cache.buf[sizeof(head_cache.buf)];
		//NOTE: the ms is less than 100,
		//and the head_cache.str is ensure enough
		//so use sprintf instead of snprintf
		n = snprintf(
			head_cache.mstr,
			end - head_cache.mstr,
			".%03d ", ms
		);
		head_cache.tstr = head_cache.mstr + n;
		//fallthrough
	case BUILD_TRACE:
		for (n = 15; n >= 0; n--) {
			head_cache.tstr[n] = hex[traceid & 0xf];
			traceid >>= 4;
		}
		head_cache.tstr[16] = ' ';
		head_cache.term = head_cache.tstr + 17;
		break;
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

