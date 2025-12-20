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
#include "args.h"
#include "mem.h"
#include "daemon.h"
#include "trace.h"
#include "log.h"
#include "timer.h"
#include "engine.h"

#define ARRAY_SIZE(a) (sizeof(a) / sizeof(a[0]))

static void print_help(const char *selfname)
{
	const char *help[] = {
		"-h, --help                Show this help message",
		"-v, --version             Show version",
		"-d, --daemon              Run as a daemon",
		"-l, --log-level LEVEL     Set logging level (debug, info, warn, error)",
		"    --log-path PATH       Path for the log file (effective with --daemon)",
		"    --pid-file FILE       Path for the PID file (effective with --daemon)",
		"-L, --lualib-path PATH    Path for Lua libraries (package.path)",
		"-C, --lualib-cpath PATH   Path for C Lua libraries (package.cpath)",
		"-S, --socket-affinity CPU Bind socket thread to specific CPU core",
		"-W, --worker-affinity CPU Bind worker thread to specific CPU core",
		"-T, --timer-affinity CPU  Bind timer thread to specific CPU core",
	};
	printf("Usage: %s [script] [options] [--key=value ...]\n", selfname);
	printf("\nModes:\n");
	printf("  %s                 Start in REPL mode\n", selfname);
	printf("  %s script.lua      Run a Lua script\n", selfname);
	printf("\nOptions:\n");
	for (size_t i = 0; i < ARRAY_SIZE(help); i++) {
		printf(" %s\n", help[i]);
	}
	printf("\nScript arguments:\n");
	printf("  --key=value pairs passed after the script\n");
	printf("  are exposed to Lua via env.get(\"key\").\n");
}

static void opt_path(char *buff, size_t size, const char *arg, const char *name)
{
	if (strlen(arg) >= size) {
		log_error("[option] %s is too long\n", name);
	}
	strncpy(buff, arg, size - 1);
}

static int opt_int(const char *arg, const char *name)
{
	char *end;
	long n = strtol(arg, &end, 10);
	if (*end != '\0') {
		log_error("[option] %s is invalid:%s\n", name, arg);
	}
	return (int)n;
}

static void parse_args(struct boot_args *args, int argc, char *argv[])
{
	int c;
	unsigned int i;
	optind = 2;
	opterr = 0;
	struct option long_options[] = {
		{ "help",            no_argument,       0, 'h' },
		{ "version",         no_argument,       0, 'v' },
		{ "daemon",          no_argument,       0, 'd' },
		{ "log-level",       required_argument, 0, 'l' },
		{ "log-path",        required_argument, 0, 0   },
		{ "pid-file",        required_argument, 0, 1   },
		{ "lualib-path",     required_argument, 0, 'L' },
		{ "lualib-cpath",    required_argument, 0, 'C' },
		{ "socket-affinity", required_argument, 0, 'S' },
		{ "worker-affinity", required_argument, 0, 'W' },
		{ "timer-affinity",  required_argument, 0, 'T' },
		{ NULL,              0,                 0, 0   }
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
		c = getopt_long(argc, argv, "hvdl:L:C:S:W:T:", long_options,
				NULL);
		if (c == -1)
			break;
		switch (c) {
		case 'h':
			print_help(args->selfname);
			exit(0);
			break;
		case 'v':
			printf("v%s\n", SILLY_RELEASE);
			exit(0);
			break;
		case 'd':
			args->daemon = 1;
			break;
		case 0:
			opt_path(args->logpath, ARRAY_SIZE(args->logpath), optarg,
				 "log-path");
			break;
		case 1:
			opt_path(args->pidfile, ARRAY_SIZE(args->pidfile), optarg,
				 "pid-file");
			break;
		case 'l':
			for (i = 0; i < ARRAY_SIZE(loglevels); i++) {
				if (strcmp(loglevels[i].name, optarg) == 0) {
					log_set_level(loglevels[i].level);
					break;
				}
			}
			if (i == ARRAY_SIZE(loglevels)) {
				log_error("[option] unknown loglevel:%s\n",
					  optarg);
			}
			break;
		case 'L':
			opt_path(args->lualib_path, ARRAY_SIZE(args->lualib_path),
				 optarg, "lualib-path");
			break;
		case 'C':
			opt_path(args->lualib_cpath, ARRAY_SIZE(args->lualib_cpath),
				 optarg, "lualib-cpath");
			break;
		case 'S':
			args->socketaffinity =
				opt_int(optarg, "socket-affinity");
			break;
		case 'W':
			args->workeraffinity =
				opt_int(optarg, "worker-affinity");
			break;
		case 'T':
			args->timeraffinity =
				opt_int(optarg, "timer-affinity");
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
	struct boot_args args;
	memset(&args, 0, sizeof(args));
	args.argc = argc;
	args.argv = argv;
	args.selfpath = argv[0];
	args.selfname = selfname(argv[0]);
	args.bootstrap[0] = '\0';
	if (argc > 1) {
		opt_path(args.bootstrap, ARRAY_SIZE(args.bootstrap), argv[1],
			 "script");
		parse_args(&args, argc, argv);
	}
	trace_init();
	daemon_start(&args);
	log_init(&args);
	timer_init();
	status = engine_run(&args);
	daemon_stop(&args);
	if (log_visible(SILLY_LOG_INFO)) {
		log_head(SILLY_LOG_INFO);
	}
	// NOTE: log_header depend timer_now
	timer_exit();
	if (log_visible(SILLY_LOG_INFO)) {
		log_fmt("%s exit, leak memory size:%zu\n", argv[0], mem_used());
	}
	log_flush();
	return status;
}
