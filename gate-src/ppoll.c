#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <netdb.h>
#include <sys/socket.h>
#include <sys/epoll.h>

#include "ppoll.h"

#define EPOLL_SIZE      32
#define PACKET_SIZE     (64 * 1024)

struct conn {
        int     fd;
        int     packet_len;
        char    *packet_buff;
};

struct ppoll {
        int                     epoll_fd;
        int                     listen_fd;
        struct epoll_event      *event_buff;
        int                     event_index;
        int                     event_cnt;
        struct conn             *curr_conn;
};



struct ppoll *P;

static int
_nonblock_it(int fd)
{
        int err;
        int flag;

        flag = fcntl(fd, F_GETFL, 0);
        if (flag < 0) {
                fprintf(stderr, "fcntl get err\n");
                return flag;
        }

        flag |= O_NONBLOCK;

        err = fcntl(fd, F_SETFL, flag);
        if (err < 0) {
                fprintf(stderr, "fcntl set err\n");
                return err;
        }

        return 0;
}

static int
_add_socket(int fd)
{
        int err;
        struct epoll_event      event;
        struct conn *c = (struct conn *)malloc(sizeof(*c));
        err = 0;
        assert(fd);
        c->fd = fd;
        c->packet_len = 0;
        c->packet_buff = (char *)malloc(sizeof(char) * PACKET_SIZE);

        event.data.ptr = c;
        event.events = EPOLLIN;
        err = epoll_ctl(P->epoll_fd, EPOLL_CTL_ADD, fd, &event);
        if (err < 0)
                close(fd);

        return err;
}

static void
_del_socket(struct conn *c)
{
        epoll_ctl(P->epoll_fd, EPOLL_CTL_DEL, c->fd, NULL);
        close(c->fd);
        free(c->packet_buff);
        //TODO:this will be replace return the socket poll to PPOLL->socket_buff
        free(c);

        return;
}

int ppoll_init()
{
        P = malloc(sizeof(*P));
        memset(P, 0, sizeof(*P));

        P->listen_fd = -1;
        //create epoll
        P->epoll_fd = epoll_create(EPOLL_SIZE + 1); //for listen fd
        assert(P->epoll_fd);
        if (P->epoll_fd == -1) {
                free(P);
                return -1;
        }

        //create event buff
        P->event_buff = (struct epoll_event *)malloc(sizeof(struct epoll_event) * EPOLL_SIZE);
        
        return 0;
}

void ppoll_exit()
{
        if (P->epoll_fd >= 0)
                close(P->epoll_fd);
        if (P->listen_fd >= 0)
                close(P->epoll_fd);

        free(P->event_buff);
        free(P);

        //TODO:need to release the struct conn buff, i'll do it later
}

int ppoll_listen(int port)
{
        int fd;
        int err;
        struct sockaddr_in      addr;

        bzero(&addr, sizeof(addr));

        addr.sin_family = AF_INET;
        addr.sin_port = htons(port);
        addr.sin_addr.s_addr = htonl(INADDR_ANY);

        fd = socket(AF_INET, SOCK_STREAM, 0);
        P->listen_fd = fd;
        if (fd < 0)
                return -1;
        
        int reuse = 1;
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));

        err = bind(fd, (struct sockaddr *)&addr, sizeof(addr));
        if (err < 0)
                return -1;

        _nonblock_it(fd);

        err = listen(fd, 5);
        if (err < 0)
                return err;

        err = _add_socket(fd);
        if (err < 0) {
                fprintf(stderr, "add listen error");
                return err;
        }

        return 0;
}

const char *ppoll_pull(int *socket_fd)
{
        int i;
        int fd;
        struct epoll_event      *e_buff;
        struct conn             *c;
        int err;

        e_buff = P->event_buff;

        if (P->event_index == P->event_cnt) {
                P->event_cnt = epoll_wait(P->epoll_fd, e_buff, EPOLL_SIZE, -1);
                P->event_index = 0;
                printf("after wait:%d\n", P->listen_fd);
        }


        i = P->event_index++;
        c = (struct conn *)e_buff[i].data.ptr;
        if (e_buff[i].events & EPOLLERR ||
                e_buff[i].events & EPOLLHUP ||
                !(e_buff[i].events & EPOLLIN)) {
                fprintf(stderr, "fd:%d occurs error now, 0x%x\n", c->fd, e_buff[i].events);
                _del_socket(c);
        } else if (c->fd == P->listen_fd) {
                fd = accept(P->listen_fd, NULL, 0);
                if (fd >= 0) {
                        _add_socket(fd);
                        *socket_fd = fd;
                        return NULL;
                }
        } else {
                unsigned short psize;
                char *recv_buff = c->packet_buff + c->packet_len;
                assert(socket_fd);
                err = read(c->fd, recv_buff, PACKET_SIZE - c->packet_len);
                if (err > 0 && (c->packet_len + err) > 2) {
                        psize = ntohs(*(unsigned short *)c->packet_buff);
                        c->packet_len += err;
                        if (c->packet_len >= psize + 2) {
                                *socket_fd = c->fd;
                                P->curr_conn = c;
                                return c->packet_buff;
                        }
                } else if ((err == -1 && errno != EAGAIN) || err == 0) {
                        _del_socket(c);
                        fprintf(stderr, "fd:%d close or occurs error\n", c->fd);
                }
        }

        P->curr_conn = NULL;
        *socket_fd = -1;
        return NULL;
}

void ppoll_push()
{
        int more;
        unsigned short psize;
        struct conn *c;

        assert(P->curr_conn);
        c = P->curr_conn;

        psize = ntohs(*(unsigned short *)c->packet_buff);

        more = c->packet_len - psize - 2;
        printf("push-->data len:%d\n", more);
        if (more > 0)
                memmove(c->packet_buff, c->packet_buff + psize + 2, more);

        c->packet_len = more;
}


int ppoll_send(int fd, char *buff)
{
       unsigned short len = ntohs(*((unsigned short *)buff));

       send(fd, buff, len + 2, 0);

       return 0;
}
