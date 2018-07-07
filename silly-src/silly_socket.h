#ifndef _EVENT_H
#define _EVENT_H

#include <stdint.h>
//sid == socket number, it will be remap in silly_socket, not a real socket fd

typedef void (*silly_finalizer_t)(void *ptr);


int silly_socket_init();
void silly_socket_exit();
void silly_socket_terminate();

int silly_socket_listen(const char *ip, const char *port, int backlog);
int silly_socket_connect(const char *ip, const char *port,
		const char *bindip, const char *bindport);
int silly_socket_udpbind(const char *ip, const char *port);
int silly_socket_udpconnect(const char *ip, const char *port,
		const char *bindip, const char *bindport);
int silly_socket_salen(const void *data);
const char *silly_socket_ntop(const void *data, int *size);

int silly_socket_send(int sid, uint8_t *buff, size_t sz,
	silly_finalizer_t finalizer);
int silly_socket_udpsend(int sid, uint8_t *buff, size_t sz,
	const uint8_t *addr, size_t addrlen, silly_finalizer_t finalizer);
int silly_socket_close(int sid);

int silly_socket_poll();

const char *silly_socket_pollapi();

#endif


