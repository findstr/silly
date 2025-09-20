#ifndef _SOCKET_H
#define _SOCKET_H

#include <stdint.h>
#include <stdatomic.h>
#include "silly.h"

int socket_init();
void socket_exit();
void socket_terminate();
const struct silly_socket_msgtype *socket_msg_types();

socket_id_t socket_tcp_listen(const char *ip, const char *port, int backlog);
socket_id_t socket_udp_bind(const char *ip, const char *port);
socket_id_t socket_tcp_connect(const char *ip, const char *port,
			       const char *bindip, const char *bindport);
socket_id_t socket_udp_connect(const char *ip, const char *port,
			       const char *bindip, const char *bindport);

int socket_salen(const void *data);
int socket_ntop(const void *data, char name[SILLY_SOCKET_NAMELEN]);

void socket_read_enable(socket_id_t sid, int enable);
int socket_send_size(socket_id_t sid);

int socket_tcp_send(socket_id_t sid, uint8_t *buff, size_t sz,
		    void (*free)(void *));
int socket_udp_send(socket_id_t sid, uint8_t *buff, size_t sz,
		    const uint8_t *addr, size_t addrlen, void (*free)(void *));
int socket_close(socket_id_t sid);

int socket_poll();

const char *socket_pollapi();

void socket_netstat(struct silly_netstat *stat);
void socket_stat(socket_id_t sid, struct silly_socketstat *info);

#endif
