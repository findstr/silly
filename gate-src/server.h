#ifndef _SERVER_H
#define _SERVER_H

struct server;

struct server *server_create();
void server_free(struct server *S);

int server_send(struct server *S, int fd, const char *buff);
const char *server_read(struct server *S, int *fd);


#endif
