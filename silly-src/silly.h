#ifndef _SILLY_H
#define _SILLY_H
#include <assert.h>
#include <stdint.h>
#include <limits.h>
#include <lua.h>

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
#define SILLY_VERSION_MINOR 6
#define SILLY_VERSION_RELEASE 0
#define SILLY_VERSION_NUM ((SILLY_VERSION_MAJOR * 100) + SILLY_VERSION_MINOR)
#define SILLY_VERSION STR(SILLY_VERSION_MAJOR) "." STR(SILLY_VERSION_MINOR)
#define SILLY_RELEASE SILLY_VERSION "." STR(SILLY_VERSION_RELEASE)

#define tocommon(msg) ((struct silly_message *)(msg))
#define totexpire(msg) ((struct silly_message_texpire *)(msg))
#define tosocket(msg) ((struct silly_message_socket *)(msg))
#define tosignal(msg) ((struct silly_message_signal *)(msg))

#define COMMONFIELD                 \
	struct silly_message *next; \
	int (*unpack)(lua_State *L, struct silly_message *msg); \
	enum silly_message_type type;

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
	SILLY_SIGNAL = 1,           //signal
	SILLY_TIMER_EXPIRE = 3,     //timer expire
	SILLY_SOCKET_LISTEN = 4,    //async listen ok
	SILLY_SOCKET_CONNECT = 5,   //async connect result
	SILLY_SOCKET_ACCEPT = 6,    //new conneting
	SILLY_SOCKET_DATA = 7,      //data packet(raw) from client
	SILLY_SOCKET_UDP = 8,       //data packet(raw) from client(udp)
	SILLY_SOCKET_CLOSE = 9,     //error from client
	SILLY_HIVE_DONE = 10,       //task done
};

struct silly_message {
	COMMONFIELD
};

struct silly_message_texpire { //timer expire
	COMMONFIELD
	uint64_t session;
	uint64_t userdata;
};

struct silly_message_socket { //socket accept
	COMMONFIELD
	socket_id_t sid;
	union {
		struct {
			int err;
		} connect;
		struct {
			int err;
		} listen;
		struct {
			socket_id_t listenid;
			uint8_t *addr;
		} accept;
		struct {
			size_t size;
			uint8_t *ptr;
		} data;
		struct {
			int err;
		} close;
	} u;
};

struct silly_message_signal { //signal
	COMMONFIELD
	int signum;
};

struct silly_message_stdin { //stdin
	COMMONFIELD
	int size;
	uint8_t data[1];
};

static inline void silly_message_free(struct silly_message *msg)
{
	int type = msg->type;
	if (type == SILLY_SOCKET_DATA || type == SILLY_SOCKET_UDP)
		silly_free(tosocket(msg)->u.data.ptr);
	silly_free(msg);
}

#endif
