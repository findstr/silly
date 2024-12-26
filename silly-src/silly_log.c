#include <stdio.h>
#include <stdarg.h>
#include <string.h>
#include <time.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/time.h>
#include <sys/file.h>

#include "silly.h"
#include "compiler.h"
#include "silly_timer.h"
#include "silly_trace.h"
#include "silly_log.h"

#ifdef __WIN32
#define localtime_r(t, tm) localtime_s(tm, t)
#endif

static int is_daemon = 0;
static enum silly_log_level log_level;
static __thread struct {
	char buf[64];
	char *sstr;
	char *tstr;
	char *term;
	time_t sec;
	time_t msec;
	silly_traceid_t traceid;
} head_cache = {
	"", NULL, NULL, NULL, 0, 0, 0,
};

static char level_names[] = {
	'D',
	'I',
	'W',
	'E',
};

static char hex[] = {
	'0', '1', '2', '3', '4', '5', '6', '7',
	'8', '9', 'a', 'b', 'c', 'd', 'e', 'f',
};

void silly_log_openfile(const char *path)
{
	int fd;
	if (!is_daemon) {
		return;
	}
	fd = open(path, O_CREAT | O_WRONLY | O_APPEND, 00666);
	if (fd >= 0) {
		dup2(fd, 1);
		dup2(fd, 2);
		close(fd);
		setvbuf(stdout, NULL, _IOFBF, LOG_BUF_SIZE);
		setvbuf(stderr, NULL, _IOLBF, LOG_BUF_SIZE);
	}
}

void silly_log_init(const struct silly_config *config)
{
	log_level = SILLY_LOG_INFO;
	is_daemon = config->daemon;
	silly_log_openfile(config->logpath);
	return;
}

void silly_log_setlevel(enum silly_log_level level)
{
	if (level >= sizeof(level_names) / sizeof(level_names[0])) {
		//TODO:
		return;
	}
	log_level = level;
}

enum silly_log_level silly_log_getlevel()
{
	return log_level;
}

#define BUILD_SEC (1)
#define BUILD_TRACE (2)
#define BUILD_NONE (3)

static inline void fmttime()
{
	int n;
	char *end;
	struct tm tm;
	uint64_t now = silly_timer_now();
	time_t sec = now / 1000;
	silly_traceid_t traceid = silly_trace_get();
	int build_step;
	if (head_cache.sstr == NULL) {
		build_step = BUILD_SEC;
		head_cache.sstr = head_cache.buf;
	} else if (sec != head_cache.sec) {
		build_step = BUILD_SEC;
		head_cache.sec = sec;
	} else if (traceid != head_cache.traceid) {
		build_step = BUILD_TRACE;
		head_cache.traceid = traceid;
	} else {
		build_step = BUILD_NONE;
	}
	switch (build_step) {
	case BUILD_SEC:
		end = &head_cache.buf[sizeof(head_cache.buf)];
		localtime_r(&sec, &tm);
		n = strftime(head_cache.sstr, end - head_cache.sstr,
			     "%Y-%m-%d %H:%M:%S ", &tm);
		head_cache.tstr = head_cache.sstr + n;
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

void silly_log_head(enum silly_log_level level)
{
	fmttime();
	head_cache.term[0] = level_names[level];
	head_cache.term[1] = ' ';
	fwrite(head_cache.buf, sizeof(char),
	       head_cache.term + 2 - head_cache.buf, stdout);
}

void silly_log_fmt(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	vfprintf(stdout, fmt, ap);
	va_end(ap);
	return;
}

void silly_log_append(const char *str, size_t sz)
{
	fwrite(str, sizeof(char), sz, stdout);
}

void silly_log_flush()
{
	fflush(stdout);
}
