#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/file.h>

#include "silly.h"
#include "silly_daemon.h"
#include "silly_log.h"

#ifndef __WIN32

static int pidfile;
extern int daemon(int, int);

static void pidfile_create(const struct silly_config *conf)
{
	int err;
	const char *path = conf->pidfile;
	pidfile = -1;
	if (path[0] == '\0')
		return;
	pidfile = open(path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR);
	if (pidfile == -1) {
		silly_log_error("[pidfile] create '%s' fail:%s\n", path,
				strerror(errno));
		exit(-1);
	}
	err = flock(pidfile, LOCK_NB | LOCK_EX);
	if (err == -1) {
		char pid[128];
		FILE *fp = fdopen(pidfile, "r+");
		err = fscanf(fp, "%s\n", pid);
		(void)err;
		silly_log_error("[pidfile] lock '%s' fail,"
				"another instace of '%s' alread run\n",
				path, pid);
		fclose(fp);
		exit(-1);
	}
	err = ftruncate(pidfile, 0);
	(void)err;
	return;
}

static inline void pidfile_write()
{
	ssize_t sz;
	ssize_t writen;
	char pid[128];
	if (pidfile == -1)
		return;
	sz = sprintf(pid, "%d\n", (int)getpid());
	writen = write(pidfile, pid, sz);
	if (writen == -1 || writen != sz) {
		perror("write pidfile");
		exit(1);
	}
	return;
}

static inline void pidfile_delete(const struct silly_config *conf)
{
	if (pidfile == -1)
		return;
	close(pidfile);
	unlink(conf->pidfile);
	return;
}

void silly_daemon_start(const struct silly_config *conf)
{
	int err;
	if (!conf->daemon)
		return;
	pidfile_create(conf);
	err = daemon(1, 0);
	if (err < 0) {
		pidfile_delete(conf);
		silly_log_error("[daemon] %s\n", strerror(errno));
		exit(0);
	}
	pidfile_write();
	return;
}

void silly_daemon_stop(const struct silly_config *conf)
{
	if (!conf->daemon)
		return;
	pidfile_delete(conf);
	return;
}

#else

void silly_daemon_start(const struct silly_config *conf)
{
	if (conf->daemon) {
		silly_log_error("[daemon] platform unsupport daemon\n");
		exit(0);
	}
}

void silly_daemon_stop(const struct silly_config *conf)
{
	(void)conf;
}

#endif