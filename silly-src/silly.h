#ifndef _SILLY_H
#define _SILLY_H
#include <assert.h>
#include <stdint.h>
#include <limits.h>
#include "silly_conf.h"
#include "silly_malloc.h"
#include "silly_socket.h"

#ifndef PATH_MAX
#define PATH_MAX 256
#endif

#ifndef SILLY_GIT_SHA1
#define SILLY_GIT_SHA1 0
#endif

#define SILLY_VERSION_MAJOR 0
#define SILLY_VERSION_MINOR 5
#define SILLY_VERSION_RELEASE 0
#define SILLY_VERSION_NUM ((SILLY_VERSION_MAJOR * 100) + SILLY_VERSION_MINOR)
#define SILLY_VERSION STR(SILLY_VERSION_MAJOR) "." STR(SILLY_VERSION_MINOR)
#define SILLY_RELEASE SILLY_VERSION "." STR(SILLY_VERSION_RELEASE)


#define tocommon(msg)   ((struct silly_message *)(msg))
#define totexpire(msg)  ((struct silly_message_texpire *)(msg))
#define tosocket(msg)   ((struct silly_message_socket *)(msg))
#define COMMONFIELD struct silly_message *next; enum silly_message_type type;


struct silly_config {
	int daemon;
	int socketaffinity;
	int workeraffinity;
	int timeraffinity;
	int argc;
	char **argv;
	const char *selfname;
	char bootstrap[PATH_MAX];
	char lualib_path[PATH_MAX];
	char lualib_cpath[PATH_MAX];
	char logpath[PATH_MAX];
	char pidfile[PATH_MAX];
};


enum silly_message_type {
	SILLY_TEXPIRE		= 1,
	SILLY_SACCEPT		= 2,	//new connetiong
	SILLY_SCLOSE,			//close from client
	SILLY_SCONNECTED,		//async connect result
	SILLY_SDATA,			//data packet(raw) from client
	SILLY_SUDP,			//data packet(raw) from client(udp)
};

struct silly_message {
	COMMONFIELD
};

struct silly_message_texpire {	//timer expire
	COMMONFIELD
	uint64_t session;
	uint64_t userdata;
};

struct silly_message_socket {	//socket accept
	COMMONFIELD
	int sid;
	//SACCEPT, it used as portid,
	//SCLOSE used as errorcode
	//SDATA/SUDP  used by length
	int ud;
	uint8_t *data;
};

static inline void
silly_message_free(struct silly_message *msg)
{
	int type = msg->type;
	if (type == SILLY_SDATA || type == SILLY_SUDP)
		silly_free(tosocket(msg)->data);
	silly_free(msg);
}

#endif

