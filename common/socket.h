#ifndef _SOCKET_H
#define _SOCKET_H

int socket_init(int fd);
void socket_exit();

const char *socket_pull(int *fd, int *size);

int socket_send(int fd, unsigned char *buff, int size);

#endif
