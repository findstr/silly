#ifndef _PPOLL_H
#define _PPOLL_H

int ppoll_init();
void ppoll_exit();

int ppoll_listen(int port);

int ppoll_pull(int *socket_fd, const char **buff);
void ppoll_push();

int ppoll_addsocket(int fd);

int ppoll_send(int fd, const char *buff);


#endif
