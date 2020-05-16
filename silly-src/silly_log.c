#include <stdio.h>
#include <stdarg.h>
#include <time.h>
#include <unistd.h>
#include <sys/time.h>
#include "silly.h"
#include "silly_log.h"

static pid_t pid;

void
silly_log_start()
{
	pid = getpid();
	return ;
}

void
silly_log_raw(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	vfprintf(stdout, fmt, ap);
	va_end(ap);
	return ;
}

void
silly_log_lstr(const char *str, size_t sz)
{
	fwrite(str, sizeof(char), sz, stdout);
}

void
silly_log(const char *fmt, ...)
{
	int nr;
	va_list ap;
	char head[64];
	struct tm tm;
	struct timeval tv;
	gettimeofday(&tv, NULL);
	localtime_r(&tv.tv_sec, &tm);
	nr = snprintf(head, sizeof(head), "%d ", pid);
	nr += strftime(&head[nr], sizeof(head) - nr,
		"%b %d %H:%M:%S.", localtime(&tv.tv_sec));
	nr += snprintf(&head[nr], sizeof(head) - nr,
		"%03d ", (int)tv.tv_usec / 1000);
	fwrite(head, sizeof(char), nr, stdout);
	va_start(ap, fmt);
	vfprintf(stdout, fmt, ap);
	va_end(ap);
	return ;
}

