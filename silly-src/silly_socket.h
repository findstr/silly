#ifndef _SILLY_SOCKET_H
#define _SILLY_SOCKET_H

#include <stdint.h>
#include "net.h"
//sid == socket number, it will be remap in silly_socket, not a real socket fd

#define SOCKET_NAMELEN (INET6_ADDRSTRLEN + 8 + 1) //[ipv6]:port
#define SOCKET_READ_PAUSE (0)
#define SOCKET_READ_ENABLE (1)

typedef void (*silly_finalizer_t)(void *ptr);

struct silly_netstat {
	int connecting;
	int tcpclient;
	size_t recvsize;
	size_t sendsize;
};

struct silly_socketstat {
	int sid;
	int fd;
	const char *type;
	const char *protocol;
	size_t sendsize;
	char localaddr[SOCKET_NAMELEN];
	char remoteaddr[SOCKET_NAMELEN];
};

int silly_socket_init();
void silly_socket_exit();
void silly_socket_terminate();
const char *silly_socket_lasterror();
int silly_socket_listen(const char *ip, const char *port, int backlog);
int silly_socket_connect(const char *ip, const char *port, const char *bindip,
			 const char *bindport);
int silly_socket_udpbind(const char *ip, const char *port);
int silly_socket_udpconnect(const char *ip, const char *port,
			    const char *bindip, const char *bindport);

int silly_socket_salen(const void *data);
int silly_socket_ntop(const void *data, char name[SOCKET_NAMELEN]);

void silly_socket_readctrl(int sid, int ctrl);
int silly_socket_sendsize(int sid);

int silly_socket_send(int sid, uint8_t *buff, size_t sz,
		      silly_finalizer_t finalizer);
int silly_socket_udpsend(int sid, uint8_t *buff, size_t sz, const uint8_t *addr,
			 size_t addrlen, silly_finalizer_t finalizer);
int silly_socket_close(int sid);

int silly_socket_poll();

const char *silly_socket_pollapi();

int silly_socket_ctrlcount();
struct silly_netstat *silly_socket_netstat();
void silly_socket_socketstat(int sid, struct silly_socketstat *info);

#endif
