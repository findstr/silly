#include <unistd.h>
#include <fcntl.h>
#include <sys/file.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>

#include "silly.h"
#include "silly_daemon.h"

static FILE *pidfile;
extern int daemon(int, int);

static void
pidfile_create(struct silly_config *config)
{
	int fd;
	int err;
	const char *path = config->pidfile;
	pidfile = NULL;
	if (path[0] == '\0')
		return ;
	fd = open(path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR);
	if (fd == -1) {
		perror("open");
		fprintf(stderr, "[pidfile] create '%s' fail.\n", path);
		exit(-1);
	}
	err = flock(fd, LOCK_NB | LOCK_EX);
	if (err == -1) {
		char pid[128];
		pidfile = fdopen(fd, "r+");
		fscanf(pidfile, "%s\n", pid);
		fprintf(stderr, "[pidfile] lock '%s' fail,"
			"another instace of '%s' alread run\n",
			path, pid);
		fclose(pidfile);
		pidfile = NULL;
		exit(-1);
	}
	ftruncate(fd, 0);
	pidfile = fdopen(fd, "r+");
	fprintf(pidfile, "%d\n", (int)getpid());
	fclose(pidfile);
	return ;
}

static void
pidfile_delete(struct silly_config *config)
{
	if (pidfile == NULL)
		return ;
	unlink(config->pidfile);
	return ;
}

void
silly_daemon_start(struct silly_config *config)
{
	int fd;
	int err;
	char path[128];
	if (!config->daemon)
		return ;
	err = daemon(1, 0);
	if (err < 0) {
		perror("DAEMON");
		exit(0);
	}
	pidfile_create(config);
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
silly_daemon_stop(struct silly_config *config)
{
	if (!config->daemon)
		return ;
	pidfile_delete(config);
	return ;
}
