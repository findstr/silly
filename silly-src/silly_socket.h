#ifndef _EVENT_H
#define _EVENT_H

//sid == socket number, it will be remap in silly_socket, not a real socket fd
//will execuate the HASH balance when work_id is -1
//PTYPE == packet type


int silly_socket_init();
void silly_socket_exit();

int silly_socket_listen(int port, int work_id);

int silly_socket_connect(const char *addr, int port, int work_id);
void silly_socket_kick(int sid);

int silly_socket_send(int sid, char *buff,  int size);

int silly_socket_run();

#endif


