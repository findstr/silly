#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <errno.h>
#include <unistd.h>
#include <signal.h>

#include "server.h"

struct server {
        int fd;
        int pid;
};

struct server *server_create()
{
        int err;
        int fd[2];
        int child;
        struct server *S;

        err = socketpair(AF_UNIX, SOCK_STREAM, 0, fd);
        if (err < 0) {
                fprintf(stderr, "socketpair error:%d\n", errno);
                return NULL;
        }

        child = fork();
        if (child == -1) {
                printf("fork error %d", errno);
                close(fd[0]);
                close(fd[1]);
                return NULL;
        } else if (child != 0) {       //parent
                close(fd[1]);
 
                printf("fork parent\n");

                S = (struct server *)malloc(sizeof(*S));
                memset(S, 0, sizeof(*S));
                S->fd = fd[0];
                S->pid = child;
                return S;
        } else {                        //child
                close(fd[0]);

                printf("fork child\n");

                char buff[3];
                char *arg[] = {
                        "server",
                        buff,
                        NULL,
                };

                sprintf(buff, "%d", fd[1]);
                execvp("./server", arg);
                printf("exec:%d\n", errno);
                return NULL;
        }
}

void server_free(struct server *S)
{
        kill(S->pid, SIGKILL);
        close(S->fd);
        free(S);

        return ;
}

int server_getfd(struct server *S)
{
        return S->fd;
}



