#ifndef _SERVER_H
#define _SERVER_H

struct server;

struct server *server_create();
void server_free(struct server *S);

int server_getfd(struct server *S);

#endif
