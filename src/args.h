#ifndef _ARGS_H
#define _ARGS_H

#include "silly_conf.h"

struct boot_args {
	int daemon;
	int socketaffinity;
	int workeraffinity;
	int timeraffinity;
	int argc;
	char **argv;
	const char *selfpath;
	const char *selfname;
	char bootstrap[PATH_MAX];
	char lualib_path[PATH_MAX];
	char lualib_cpath[PATH_MAX];
	char logpath[PATH_MAX];
	char pidfile[PATH_MAX];
};

#endif