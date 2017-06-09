#ifndef _EVENT_H
#define _EVENT_H

#include <stdint.h>
//sid == socket number, it will be remap in silly_socket, not a real socket fd

typedef void (*silly_finalizer_t)(void *ptr, size_t sz);


int silly_socket_init();
void silly_socket_exit();
void silly_socket_terminate();

int silly_socket_listen(const char *ip, uint16_t port, int backlog);
int silly_socket_connect(const char *addr, int port, const char *bindip, int bindport);

int silly_socket_udpbind(const char *ip, uint16_t port);
int silly_socket_udpconnect(const char *addr, int port, const char *bindip, int bindport);
const char *silly_socket_udpaddress(const char *data, size_t *addrlen);

int silly_socket_send(int sid, uint8_t *buff, size_t sz, silly_finalizer_t finalizer);
int silly_socket_udpsend(int sid, uint8_t *buff, size_t sz, const char *addr, size_t addrlen, silly_finalizer_t finalizer);

int silly_socket_close(int sid);

int silly_socket_poll();

#endif


