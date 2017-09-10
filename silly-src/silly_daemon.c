#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>

#include "silly.h"
#include "silly_daemon.h"
#include "silly_log.h"

static int pidfile;
extern int daemon(int, int);

static void
pidfile_create(const struct silly_config *config)
{
	int err;
	const char *path = config->pidfile;
	pidfile = -1;
	if (path[0] == '\0')
		return ;
	pidfile = open(path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR);
	if (pidfile == -1) {
		silly_log("[pidfile] create '%s' fail:%s\n", path,
				strerror(errno));
		exit(-1);
	}
	err = flock(pidfile, LOCK_NB | LOCK_EX);
	if (err == -1) {
		char pid[128];
		FILE *fp = fdopen(pidfile, "r+");
		fscanf(fp , "%s\n", pid);
		silly_log("[pidfile] lock '%s' fail,"
			"another instace of '%s' alread run\n",
			path, pid);
		fclose(fp);
		exit(-1);
	}
	ftruncate(pidfile, 0);
	return ;
}

static inline void
pidfile_write()
{
	int sz;
	char pid[128];
	if (pidfile == -1)
		return ;
	sz = sprintf(pid, "%d\n", (int)getpid());
	write(pidfile, pid, sz);
	return ;
}

static inline void
pidfile_delete(const struct silly_config *config)
{
	if (pidfile == -1)
		return ;
	close(pidfile);
	unlink(config->pidfile);
	return ;
}

void
silly_daemon_start(const struct silly_config *config)
{
	int fd;
	int err;
	char path[128];
	if (!config->daemon)
		return ;
	pidfile_create(config);
	err = daemon(1, 0);
	if (err < 0) {
		pidfile_delete(config);
		silly_log("[daemon] %s\n", strerror(errno));
		exit(0);
	}
	pidfile_write();
	snprintf(path, 128, "%s%s-%d.log", config->logpath, config->selfname, getpid());
	fd = open(path, O_CREAT | O_RDWR | O_TRUNC, 00666);
	if (fd >= 0) {
		dup2(fd, 1);
		dup2(fd, 2);
		close(fd);
		setvbuf(stdout, NULL, _IOLBF, 0);
		setvbuf(stderr, NULL, _IOLBF, 0);
	}
	return ;
}

void
silly_daemon_stop(const struct silly_config *config)
{
	if (!config->daemon)
		return ;
	pidfile_delete(config);
	return ;
}
