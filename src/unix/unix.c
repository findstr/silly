#include <stdio.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <stdlib.h>

#include "log.h"
#include "compiler.h"
#include "unix.h"

void nonblock(fd_t fd)
{
	int err;
	int flag;
	flag = fcntl(fd, F_GETFL, 0);
	if (unlikely(flag < 0)) {
		log_error("[unix] nonblock F_GETFL fd:%d error:%s\n",
				fd, strerror(errno));
		return;
	}
	flag |= O_NONBLOCK;
	err = fcntl(fd, F_SETFL, flag);
	if (unlikely(err < 0)) {
		log_error("[unix] nonblock fd:%d F_SETFL:%s\n",
				fd, strerror(errno));
	}
}

int open_fd_count(void)
{
	int fd_count = 0;
	struct dirent *entry;
	DIR *fd_dir = opendir("/proc/self/fd");
	if (fd_dir == NULL) {
		log_error("[metrics] failed to open /proc/self/fd");
		return 0;
	}
	while ((entry = readdir(fd_dir)) != NULL) {
		if (entry->d_name[0] != '.') {
			fd_count++;
		}
	}
	closedir(fd_dir);
	return fd_count;
}

void fd_open_limit(int *soft, int *hard)
{
	struct rlimit rlim;
	int ret = getrlimit(RLIMIT_NOFILE, &rlim);
	if (ret != 0) {
		log_error("[metrics] getrlimit errno:%d", errno);
		rlim.rlim_cur = 0;
		rlim.rlim_max = 0;
	}
	*soft = rlim.rlim_cur;
	*hard = rlim.rlim_max;
}

void cpu_usage(float *stime, float *utime)
{
	struct rusage ru;
	getrusage(RUSAGE_SELF, &ru);
	*stime = (float)ru.ru_stime.tv_sec;
	*stime += (float)ru.ru_stime.tv_usec / 1000000;
	*utime = (float)ru.ru_utime.tv_sec;
	*utime += (float)ru.ru_utime.tv_usec / 1000000;
}

void signal_ignore_pipe(void)
{
	signal(SIGPIPE, SIG_IGN);
}

void signal_block_usr2(void)
{
	sigset_t set;
	sigemptyset(&set);
	sigaddset(&set, SIGUSR2);
	pthread_sigmask(SIG_BLOCK, &set, NULL);
}

void signal_register_usr2(void (*handler)(int))
{
	sigset_t set;
	sigemptyset(&set);
	sigaddset(&set, SIGUSR2);
	pthread_sigmask(SIG_UNBLOCK, &set, NULL);
	signal(SIGUSR2, handler);
}

void signal_kill_usr2(pthread_t tid)
{
	pthread_kill(tid, SIGUSR2);
}

size_t memory_rss_(void)
{
	size_t rss;
	char *p, *end;
	int i, fd, err;
	char buf[4096];
	char filename[256];
	int page = sysconf(_SC_PAGESIZE);
	snprintf(filename, sizeof(filename), "/proc/%d/stat", getpid());
	fd = open(filename, O_RDONLY);
	if (fd == -1)
		return 0;
	err = read(fd, buf, 4095);
	close(fd);
	if (err <= 0)
		return 0;
	//RSS is the 24th field in /proc/$pid/stat
	i = 0;
	p = buf;
	end = &buf[err];
	while (p < end) {
		if (*p++ != ' ')
			continue;
		if ((++i) == 23)
			break;
	}
	if (i != 23)
		return 0;
	end = strchr(p, ' ');
	if (end == NULL)
		return 0;
	*end = '\0';
	rss = strtoll(p, NULL, 10) * page;
	return rss;
}
