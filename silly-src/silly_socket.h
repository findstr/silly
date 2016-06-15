#ifndef _EVENT_H
#define _EVENT_H

#include <stdint.h>
//sid == socket number, it will be remap in silly_socket, not a real socket fd
//will execuate the HASH balance when work_id is -1
//PTYPE == packet type


int silly_socket_init();
void silly_socket_exit();
void silly_socket_terminate();

int silly_socket_listen(const char *ip, uint16_t port, int backlog);
int silly_socket_connect(const char *addr, int port);
int silly_socket_close(int sid);
int silly_socket_send(int sid, uint8_t *buff,  size_t size);

int silly_socket_poll();

#endif


