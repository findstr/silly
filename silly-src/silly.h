#ifndef _SILLY_H
#define _SILLY_H
#include "silly_conf.h"
#include <assert.h>
#include <stdint.h>
#include <limits.h>
#include "silly_malloc.h"

#ifndef PATH_MAX
#define PATH_MAX 256
#endif

#ifndef SILLY_GIT_SHA1
#define SILLY_GIT_SHA1 0
#endif

#define SILLY_VERSION_MAJOR 0
#define SILLY_VERSION_MINOR 6
#define SILLY_VERSION_RELEASE 0
#define SILLY_VERSION_NUM ((SILLY_VERSION_MAJOR * 100) + SILLY_VERSION_MINOR)
#define SILLY_VERSION STR(SILLY_VERSION_MAJOR) "." STR(SILLY_VERSION_MINOR)
#define SILLY_RELEASE SILLY_VERSION "." STR(SILLY_VERSION_RELEASE)

#define ARRAY_SIZE(a) (sizeof(a) / sizeof(a[0]))



struct silly_config {
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

enum silly_message_type {
	SILLY_TEXPIRE = 1,    //timer expire
	SILLY_SACCEPT = 2,    //new connetiong
	SILLY_SCLOSE = 3,     //close from client
	SILLY_SCONNECTED = 4, //async connect result
	SILLY_SDATA = 5,      //data packet(raw) from client
	SILLY_SUDP = 6,       //data packet(raw) from client(udp)
	SILLY_SIGNAL = 7,     //signal
	SILLY_STDIN = 8,      //stdin
};

#include "message.h"

#endif
