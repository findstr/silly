#include <assert.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <getopt.h>
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>
#include <string.h>
#include "silly.h"
#include "silly_daemon.h"
#include "silly_trace.h"
#include "silly_log.h"
#include "silly_timer.h"
#include "silly_run.h"

#define ARRAY_SIZE(a) (sizeof(a) / sizeof(a[0]))

static void print_help(const char *selfname)
{
	const char *help[] = {
		"-h, --help                help",
		"-v, --version             version",
		"-d, --daemon              run as a daemon",
		"-p, --logpath PATH        path for the log file",
		"-l, --loglevel LEVEL      logging level (e.g. debug, info, warn, error)",
		"-f, --pidfile FILE        path for the PID file",
		"-L, --lualib_path PATH    path for Lua libraries",
		"-C, --lualib_cpath PATH   path for C Lua libraries",
		"-S, --socket_cpu_affinity affinity for socket thread",
		"-W, --worker_cpu_affinity affinity for worker threads",
		"-T, --timer_cpu_affinity  affinity for timer thread",
	};
	printf("Usage: %s main.lua [options]\n", selfname);
	printf("Options:\n");
	for (size_t i = 0; i < ARRAY_SIZE(help); i++) {
		printf(" %s\n", help[i]);
	}
}

static void parse_args(struct silly_config *config, int argc, char *argv[])
{
	int c;
	unsigned int i;
	optind = 2;
	opterr = 0;
	struct option long_options[] = {
		{ "help",                no_argument,       0, 'h' },
		{ "version",             no_argument,       0, 'v' },
		{ "daemon",              no_argument,       0, 'd' },
		{ "logpath",             required_argument, 0, 'p' },
		{ "loglevel",            required_argument, 0, 'l' },
		{ "pidfile",             required_argument, 0, 'f' },
		{ "lualib_path",         required_argument, 0, 'L' },
		{ "lualib_cpath",        required_argument, 0, 'C' },
		{ "socket_cpu_affinity", required_argument, 0, 'S' },
		{ "worker_cpu_affinity", required_argument, 0, 'W' },
		{ "timer_cpu_affinity",  required_argument, 0, 'T' },
		{ NULL,                  0,                 0, 0   }
	};
	struct {
		const char *name;
		enum silly_log_level level;
	} loglevels[] = {
		{ "debug", SILLY_LOG_DEBUG },
		{ "info",  SILLY_LOG_INFO  },
		{ "warn",  SILLY_LOG_WARN  },
		{ "error", SILLY_LOG_ERROR },
	};
	if (argc == 2 && argv[1] != NULL && argv[1][0] == '-') {
		optind = 1;
	}
	for (;;) {
		c = getopt_long(argc, argv, "hvdp:l:f:L:C:S:W:T:", long_options,
				NULL);
		if (c == -1)
			break;
		switch (c) {
		case 'h':
			print_help(config->selfname);
			exit(0);
			break;
		case 'v':
			printf("%s\n", SILLY_VERSION);
			exit(0);
			break;
		case 'd':
			config->daemon = 1;
			break;
		case 'p':
			if (strlen(optarg) >= ARRAY_SIZE(config->logpath)) {
				silly_log_error(
					"[option] logpath is too long\n");
			}
			strncpy(config->logpath, optarg,
				ARRAY_SIZE(config->logpath) - 1);
			break;
		case 'l':
			for (i = 0; i < ARRAY_SIZE(loglevels); i++) {
				if (strcmp(loglevels[i].name, optarg) == 0) {
					silly_log_setlevel(loglevels[i].level);
					break;
				}
			}
			if (i == ARRAY_SIZE(loglevels)) {
				silly_log_error(
					"[option] unknown loglevel:%s\n",
					optarg);
			}
			break;
		case 'f':
			if (strlen(optarg) >= ARRAY_SIZE(config->pidfile)) {
				silly_log_error(
					"[option] pidfile is too long\n");
			}
			strncpy(config->pidfile, optarg,
				ARRAY_SIZE(config->pidfile) - 1);
			break;
		case 'L':
			if (strlen(optarg) >= ARRAY_SIZE(config->lualib_path)) {
				silly_log_error(
					"[option] lualib_path is too long\n");
			}
			strncpy(config->lualib_path, optarg,
				ARRAY_SIZE(config->lualib_path) - 1);
			break;
		case 'C':
			if (strlen(optarg) >=
			    ARRAY_SIZE(config->lualib_cpath)) {
				silly_log_error(
					"[option] lualib_cpath is too long\n");
			}
			strncpy(config->lualib_cpath, optarg,
				ARRAY_SIZE(config->lualib_cpath) - 1);
			break;
		case 'S':
			config->socketaffinity = atoi(optarg);
			break;
		case 'W':
			config->workeraffinity = atoi(optarg);
			break;
		case 'T':
			config->timeraffinity = atoi(optarg);
			break;
		case '?':
			break;
		}
	}
}

static const char *selfname(const char *path)
{
	size_t len = strlen(path);
	const char *end = &path[len];
	while (end-- > path) {
		if (*end == '/' || *end == '\\')
			break;
	}
	return (end + 1);
}

int main(int argc, char *argv[])
{
	int status;
	struct silly_config config;
	memset(&config, 0, sizeof(config));
	config.argc = argc;
	config.argv = argv;
	config.selfpath = argv[0];
	config.selfname = selfname(argv[0]);
	config.bootstrap[0] = '\0';
	if (argc > 1) {
		strncpy(config.bootstrap, argv[1], ARRAY_SIZE(config.bootstrap) - 1);
		parse_args(&config, argc, argv);
	}
	silly_trace_init();
	silly_daemon_start(&config);
	silly_log_init(&config);
	silly_timer_init();
	status = silly_run(&config);
	silly_daemon_stop(&config);
	silly_timer_exit();
	silly_log_info("%s exit, leak memory size:%zu\n", argv[0],
		       silly_memused());
	silly_log_flush();
	return status;
}
