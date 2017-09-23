#ifndef _SILLY_H
#define _SILLY_H
#include <assert.h>
#include <stdint.h>
#include "silly_malloc.h"
#include "silly_socket.h"

#define MSGCOMMONFIELD	\
	struct silly_message *next;\
	enum silly_message_type type;

#define tocommon(msg)   ((struct silly_message *)(msg))
#define totexpire(msg)  ((struct silly_message_texpire *)(msg))
#define tosocket(msg)   ((struct silly_message_socket *)(msg))

struct silly_listen {
	char name[64];
	char addr[64];
};

struct silly_config {
	int daemon;
	int socketaffinity;
	int workeraffinity;
	int timeraffinity;
	const char *selfname;
	//please forgive my shortsighted, i think listen max to 16 ports is very many
	char bootstrap[128];
	char lualib_path[256];
	char lualib_cpath[256];
	char logpath[256];
	char pidfile[256];
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
	MSGCOMMONFIELD
};

struct silly_message_texpire {	//timer expire
	MSGCOMMONFIELD
	uint32_t session;
};

struct silly_message_socket {	//socket accept
	MSGCOMMONFIELD
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

