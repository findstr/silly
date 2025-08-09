#ifndef _SILLY_SOCKET_H
#define _SILLY_SOCKET_H

#include <stdint.h>
#include <stdatomic.h>
#include "platform.h"

typedef int64_t socket_id_t;
//sid == socket number, it will be remap in silly_socket, not a real socket fd

#define SOCKET_NAMELEN (INET6_ADDRSTRLEN + 8 + 1) //[ipv6]:port
#define SOCKET_READ_PAUSE (0)
#define SOCKET_READ_ENABLE (1)

struct silly_netstat {
	atomic_uint_least16_t connecting;
	atomic_uint_least16_t tcpclient;
	atomic_uint_least32_t recvsize;
	atomic_uint_least32_t sendsize;
};

struct silly_socketstat {
	socket_id_t sid;
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
socket_id_t silly_socket_listen(const char *ip, const char *port, int backlog);
socket_id_t silly_socket_connect(const char *ip, const char *port, const char *bindip,
			 const char *bindport);
socket_id_t silly_socket_udpbind(const char *ip, const char *port);
socket_id_t silly_socket_udpconnect(const char *ip, const char *port,
			    const char *bindip, const char *bindport);

int silly_socket_salen(const void *data);
int silly_socket_ntop(const void *data, char name[SOCKET_NAMELEN]);

void silly_socket_readctrl(socket_id_t sid, int ctrl);
int silly_socket_sendsize(socket_id_t sid);

int silly_socket_send(socket_id_t sid, uint8_t *buff, size_t sz,
		void (*free)(void *));
int silly_socket_udpsend(socket_id_t sid, uint8_t *buff, size_t sz, const uint8_t *addr,
			 size_t addrlen, void (*free)(void *));
int silly_socket_close(socket_id_t sid);

int silly_socket_poll();

const char *silly_socket_pollapi();

int silly_socket_ctrlcount();
void silly_socket_netstat(struct silly_netstat *stat);
void silly_socket_socketstat(socket_id_t sid, struct silly_socketstat *info);

#endif
