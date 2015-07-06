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

#include "event.h"

#define EPOLL_EVENT_SIZE        100
#define PACKET_SIZE             (64 * 1024)

struct conn {
        int             fd;
        int             packet_len;
        char            *packet_buff;
};


struct event {
        int                     epoll_fd;
        int                     gate_fd;
        struct epoll_event      *event_buff;
        int                     event_index;
        int                     event_cnt;
        int                     event_send_fd;
        int                     event_recv_fd;
        int                     (*data_cb)(void *ud, enum event_ptype type, int fd, const char *buff, int size);
        void                    *data_ud;
        struct event_handler    data_handler;
};

struct event *EVENT;

static int
_add_socket(struct event *E, int fd)
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
        err = epoll_ctl(E->epoll_fd, EPOLL_CTL_ADD, fd, &event);
        if (err < 0)
                close(fd);

        return err;
}

static void
_del_socket(struct event *E, struct conn *c)
{
        epoll_ctl(E->epoll_fd, EPOLL_CTL_DEL, c->fd, NULL);
        close(c->fd);
        free(c->packet_buff);
        //TODO:this will be replace return the socket poll to PPOLL->socket_buff
        free(c);

        return;
}

int event_init()
{
        int err;
        int fd[2];
        struct epoll_event event;

        EVENT = (struct event *)malloc(sizeof(*EVENT));
        EVENT->epoll_fd = epoll_create(EPOLL_EVENT_SIZE);
        EVENT->event_buff = (struct epoll_event *)malloc(EPOLL_EVENT_SIZE * sizeof(struct epoll_event));
        EVENT->event_index = 0;
        EVENT->event_cnt = 0;
        err = socketpair(AF_LOCAL, SOCK_STREAM, 0, fd);
        if (err == -1) {
                close(EVENT->epoll_fd);
                free(EVENT->event_buff);
                free(EVENT);
                return err;
        }
        EVENT->event_send_fd = fd[0];
        EVENT->event_recv_fd = fd[1];

        event.data.ptr = NULL;  //ptr == NULL is event pipe
        event.events = EPOLLIN;
        err = epoll_ctl(EVENT->epoll_fd, EPOLL_CTL_ADD, EVENT->event_recv_fd, &event);
        if (err < 0) {
                close(fd[0]);
                close(fd[1]);
                close(EVENT->epoll_fd);
                free(EVENT->event_buff);
                free(EVENT);
                return err;
        }

        return 0;
}

void event_exit()
{
        close(EVENT->epoll_fd);
        close(EVENT->event_send_fd);
        close(EVENT->event_recv_fd);
        free(EVENT->event_buff);
        free(EVENT);

        return ;
}

int event_connect(const char *addr, int port)
{
        return 0;
}

int event_add_gatefd(int fd)
{
        EVENT->gate_fd = fd;
        return _add_socket(EVENT, fd);
}

int event_add_handler(const struct event_handler *handler)
{
        int err;
        for (;;) {
                err = write(EVENT->event_send_fd, handler, sizeof(*handler));
                if (err == -1) {
                        if (errno == EINTR)
                                continue;
                        fprintf(stderr, "add handler error\n");
                        return -1;
                }
                assert(err == sizeof(*handler));
                return 0;
        }
        return -1;
}

int event_set_datahandler(int (*cb)(void *ud, enum event_ptype type, int fd, const char *buff, int size), void *ud)
{
        EVENT->data_cb = cb;
        EVENT->data_ud = ud;
        return 0;
}

static int 
_align_socket(struct conn *c)
{
        int psize = ntohs(*((unsigned short*)(c->packet_buff)));
        if (c->packet_len <= 2)
                return 0;

        if (c->packet_len >= psize + 2) {
                int more = c->packet_len - psize - sizeof(unsigned short);
                if (more > 0)
                        memmove(c->packet_buff, c->packet_buff + psize + sizeof(unsigned short), more);
                c->packet_len = more;
        }
        return 0;
}

int event_socketsend(enum event_ptype type, int fd, const char *buff, int size)
{
        assert(type == EVENT_GDATA);
        char *b = (char *)malloc(size + sizeof(int) + sizeof(unsigned short));
        *((int *)(b + 2)) = fd;
        *((unsigned short *)b) = ntohs((unsigned short)size + 4);

        memcpy(b + 6, buff, size);

        printf("***server send:%d*****\n", size + 6);

        //TODO:need repeat send, becuase this can be interrupt
        send(EVENT->gate_fd, b, size + 6, 0);

        return 0;
}


static void
_execute_handler(struct event *E)
{
        int err;
        struct event_handler e;

        for (;;) {
                err = read(E->event_recv_fd, &e, sizeof(e));
                if (err < 0) {
                        if (errno == EINTR)
                                continue;
                        fprintf(stderr, "event control fd occurs error\n");
                        return ;
                }
                assert(err == sizeof(e));
                e.cb(e.ud);
                return ;
        }

}

int event_dispatch()
{
        int i;
        struct epoll_event      *e_buff;
        struct conn             *c;

        e_buff = EVENT->event_buff;
        if (EVENT->event_index == EVENT->event_cnt) {
                EVENT->event_cnt = epoll_wait(EVENT->epoll_fd, e_buff, EPOLL_EVENT_SIZE, -1);
                EVENT->event_index = 0;
        }

        i = EVENT->event_index++;
        c = (struct conn *)e_buff[i].data.ptr;
        if (e_buff[i].events & EPOLLERR ||
                e_buff[i].events & EPOLLHUP ||
                !(e_buff[i].events & EPOLLIN)) {
                fprintf(stderr, "fd:%d occurs error now, 0x%x\n", c ? c->fd : 99999, e_buff[i].events);
                if (c)
                        _del_socket(EVENT, c);
        }
        if (c == NULL) {  //event_recv_fd
                _execute_handler(EVENT);
        } else if (c->fd == EVENT->gate_fd) {   //event from gate
                _align_socket(c);
                char *buff = c->packet_buff + c->packet_len;
                int len = recv(c->fd, buff, PACKET_SIZE - c->packet_len, 0);
                if (len < 0) {
                        _del_socket(EVENT, c);
                        return -1;
                }

                c->packet_len += len;
                if (c->packet_len > 2) {
                        int psize = ntohs(*((unsigned short *)buff));
                        if (c->packet_len >= psize && EVENT->data_cb) {
                                int fd;
                                fd = *((int *)(c->packet_buff + 2));
                                EVENT->data_cb(EVENT->data_ud, EVENT_GDATA, fd, c->packet_buff + 4, psize);
                        }
                }
        } else {                                //event from connection
                assert(0);
        }

        return 0;

}


