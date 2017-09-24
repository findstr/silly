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
	char buffer[LOG_MAX_LEN];
	va_start(ap, fmt);
	vsnprintf(buffer, LOG_MAX_LEN, fmt, ap);
	va_end(ap);
	fprintf(stdout, "%s", buffer);
	return ;
}

void
silly_log(const char *fmt, ...)
{
	int nr;
	va_list ap;
	char head[64];
	struct timeval tv;
	char buffer[LOG_MAX_LEN];
	va_start(ap, fmt);
	vsnprintf(buffer, LOG_MAX_LEN, fmt, ap);
	va_end(ap);
	gettimeofday(&tv, NULL);
	nr = strftime(head, sizeof(head), "%b %d %H:%M:%S.",
		localtime(&tv.tv_sec));
	snprintf(head + nr, sizeof(head) - nr, "%03d", (int)tv.tv_usec/1000);
	fprintf(stdout, "%d %s %s", pid, head, buffer);
	return ;
}

