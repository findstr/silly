#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <netdb.h>
#include <arpa/inet.h>
#include <sys/socket.h>

#include "socket_poll.h"
#include "silly_message.h"
#include "silly_server.h"
#include "silly_malloc.h"

#include "silly_socket.h"

//STYPE == socket type

#define EPOLL_EVENT_SIZE        100
#define MAX_CONN                (1 << 14)
#define MIN_READBUFF_LEN        64

#define CONN_INDEX(sid)         (sid % MAX_CONN)

enum stype {
        STYPE_RESERVE,
        STYPE_ALLOCED,
        STYPE_LISTEN,
        STYPE_SOCKET,
        STYPE_CTRL,
};

struct conn {
        int             fd;
        enum stype      type;
        int             alloc_size;
        int             workid;          
};

struct silly_socket {
        int                     sp_fd;
        
        sp_event_t                *event_buff;
        int                     event_index;
        int                     event_cnt;
        
        struct conn             *conn_buff;

        //ctrl pipe, call write can be automatic wen data less then 64k(from APUE)
        int                     ctrl_send_fd;
        int                     ctrl_recv_fd;
        struct conn             *ctrl_conn;

        //reserve id(for socket fd remap)
        int                     reserve_sid;
};

struct silly_socket *SOCKET;

static inline int
_conn_to_sid(struct silly_socket *s, struct conn *c)
{
        int sid;

        sid = c - s->conn_buff;

        return sid;
}

static void 
_init_conn_buff(struct silly_socket *s)
{
        int i;
        struct conn *c = s->conn_buff;
        for (i = 0; i < MAX_CONN; i++) {
                c->fd = -1;
                c->type = STYPE_RESERVE;
                c->alloc_size = MIN_READBUFF_LEN;
                c->workid = -1;
                c++;
        }

        return ;
}

static struct conn *
_fetch_empty_conn(struct silly_socket *s)
{
        int i;
        int id;

        for (i = 0; i < MAX_CONN; i++) {
                id = __sync_add_and_fetch(&s->reserve_sid, 1);
                if (id < 0) {
                        id = -id;
                        __sync_and_and_fetch(&s->reserve_sid, 0x7fffffff);
                }
                
                struct conn *c = &s->conn_buff[CONN_INDEX(id)];

                if (c->type == STYPE_RESERVE) {
                        if (__sync_bool_compare_and_swap(&c->type, STYPE_RESERVE, STYPE_ALLOCED)) {
                                c->alloc_size = MIN_READBUFF_LEN;
                                return c;
                        }
                }
        }

        return NULL;
}

static void
_release_conn(struct conn *c)
{
        c->type = STYPE_RESERVE;

        return ;
}

int silly_socket_init()
{
        int err;
        int sp_fd;
        int fd[2];
        struct conn *c = NULL;
        
        sp_fd = _sp_create(EPOLL_EVENT_SIZE);
        if (sp_fd < 1)
                goto end;

        err = pipe(fd);
        if (err < 0)
                goto end;
 
        c = (struct conn *)silly_malloc(sizeof(struct conn));
        c->fd = fd[0];
        c->type = STYPE_CTRL;
        c->alloc_size = -1;
        c->workid = -1;

        err = _sp_add(sp_fd, fd[0], c);
        if (err < 0)
                goto end;

        struct silly_socket *s = (struct silly_socket *)silly_malloc(sizeof(*s));

        s->reserve_sid = -1;
        s->sp_fd = sp_fd;
        s->ctrl_send_fd = fd[1];
        s->ctrl_recv_fd = fd[0];
        s->event_index = 0;
        s->event_cnt = 0;
        s->event_buff = (sp_event_t *)silly_malloc(sizeof(sp_event_t) * EPOLL_EVENT_SIZE);
        s->conn_buff = (struct conn *)silly_malloc(sizeof(struct conn) * MAX_CONN);
        s->ctrl_conn = c;
        _init_conn_buff(s);

        SOCKET = s;

        return 0;
end:
        if (sp_fd >= 0)
                close(sp_fd);
        if (fd[0] >= 0)
                close(fd[0]);
        if (fd[1] >= 0)
                close(fd[0]);
        if (c)
                silly_free(c);

        return -1;
}

void silly_socket_exit()
{
        assert(SOCKET);
        close(SOCKET->sp_fd);
        close(SOCKET->ctrl_send_fd);
        close(SOCKET->ctrl_recv_fd);
        silly_free(SOCKET->event_buff);
        silly_free(SOCKET->conn_buff);
        silly_free(SOCKET->ctrl_conn);
        silly_free(SOCKET);

        return ;
}       

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
_add_socket(struct silly_socket *s, int fd, enum stype type, int workid)
{
        int err;
        int sid;
        struct conn *c;

        c = _fetch_empty_conn(s);
        if (c == NULL)
                return -1;

        sid = _conn_to_sid(s, c);
        c->fd = fd;
        c->type = type;
        c->alloc_size = MIN_READBUFF_LEN;
        if (type == STYPE_LISTEN)               //listen is the special
                c->workid = workid;
        else
                c->workid = silly_server_balance(workid, sid);

        err = _sp_add(s->sp_fd, c->fd, c);
        if (err < 0) {
                _release_conn(c);
                return -1;
        }

        return sid;
}

static void
_remove_socket(struct silly_socket *s, int sid)
{
        struct conn *c = &s->conn_buff[sid];
        _sp_del(s->sp_fd, c->fd);
        _release_conn(c);

        return ;
}

int silly_socket_listen(int port, int workid)
{
        int err;
        int fd;
        int reuse;
        struct sockaddr_in addr;

        bzero(&addr, sizeof(addr));

        addr.sin_family = AF_INET;
        addr.sin_port = htons(port);
        addr.sin_addr.s_addr = htonl(INADDR_ANY);

        fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0)
                return -1;

        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));

        err = bind(fd, (struct sockaddr *)&addr, sizeof(addr));
        if (err < 0)
                goto end;

        _nonblock_it(fd);

        err = listen(fd, 5);
        if (err < 0)
                goto end;
       
        err = _add_socket(SOCKET, fd, STYPE_LISTEN, workid);
        if (err < 0)
                goto end;

        return 0;
end:
        close(fd);
        return -1;
}

int silly_socket_connect(const char *addr, int port, int workid)
{
        //need async for epoll/kevent
        return 0;
}

static void
_report_close(struct silly_socket *s, int sid)
{
        struct silly_message *msg = (struct silly_message *)silly_malloc(sizeof(*msg));
        
        msg->type = SILLY_MESSAGE_SOCKET;
        msg->msg.socket = (struct silly_message_socket *)silly_malloc(sizeof(msg->msg.socket));

        msg->msg.socket->sid = sid;
        msg->msg.socket->type = SILLY_SOCKET_CLOSE;
        msg->msg.socket->data_size = 0;
        msg->msg.socket->data = NULL;

        silly_server_push(s->conn_buff[sid].workid, msg);
}


static void
_socket_close(struct silly_socket *s, int sid)
{
        struct conn *c = &s->conn_buff[sid];
        close(c->fd);
        _report_close(s, sid);
        _remove_socket(s, sid);

        return ;
}

void silly_socket_kick(int sid)
{
        //need async for epoll/kevent
        return ;
}

int silly_socket_send(int sid, char *buff,  int size)
{
        int err;
        assert(sid >= 0);
        struct conn *c = &SOCKET->conn_buff[sid];

        for (;;) {
                err = send(c->fd, buff, size, 0);
                if (err == size) {
                        break;
                } else if (err == 0 || (err == -1 && errno != EAGAIN && errno != EINTR)) {
                        fprintf(stderr, "_silly_socket_send return:%d, %d, %d\n",sid, err, errno);
                        _socket_close(SOCKET, sid);
                        break;
                } else if (err > 0) {
                        fprintf(stderr, "_silly_socket_send less\n");
                        assert(0);
                }
        }

        silly_free(buff);
        return 0;
}

static void
_wait(struct silly_socket *s)
{
        s->event_cnt = _sp_wait(s->sp_fd, s->event_buff, EPOLL_EVENT_SIZE);
        if (s->event_cnt == -1) {
                s->event_cnt = 0;
                fprintf(stderr, "silly_socket:_wait fail:%d\n", errno);
        }
        s->event_index = 0;
}

static void
_forward_msg(struct silly_socket *s, struct conn *c)
{
        int len;
        uint8_t *buff = (uint8_t *)silly_malloc(c->alloc_size);
        
        len = recv(c->fd, buff, c->alloc_size, 0);
        if (len < 0) {
                switch (errno) {
                case EINTR:
                        fprintf(stderr, "_forward_msg, EINTR\n");
                        break;
                case EAGAIN:
                        fprintf(stderr, "_forward_msg, EAGAIN\n");
                        break;
                default:
                        fprintf(stderr, "_forward_msg, %s\n", strerror(errno));
                        _socket_close(s, _conn_to_sid(s, c));
                        break;
                }
        } else if (len == 0) {
                _socket_close(s, _conn_to_sid(s, c));
        } else {
                assert(c->workid >= 0);
                
                struct silly_message *msg = (struct silly_message *)silly_malloc(sizeof(*msg));
                msg->type = SILLY_MESSAGE_SOCKET;
                msg->msg.socket = (struct silly_message_socket *)silly_malloc(sizeof(struct silly_message_socket));
                msg->msg.socket->type = SILLY_SOCKET_DATA;
                msg->msg.socket->sid = _conn_to_sid(s, c);
                msg->msg.socket->data_size = len;
                msg->msg.socket->data = buff;
                
                silly_server_push(c->workid, msg);         

                //to predict the pakcet size
                if (len == c->alloc_size)
                        c->alloc_size *= 2;
                else if (len < c->alloc_size && c->alloc_size > MIN_READBUFF_LEN)
                        c->alloc_size = (len / MIN_READBUFF_LEN + 1) * MIN_READBUFF_LEN;
        
        }

        return ;
}

static void
_report_accept(struct silly_socket *s, int sid)
{
        struct silly_message *msg = (struct silly_message *)silly_malloc(sizeof(*msg));
        
        msg->type = SILLY_MESSAGE_SOCKET;
        msg->msg.socket = (struct silly_message_socket *)silly_malloc(sizeof(msg->msg.socket));

        msg->msg.socket->sid = sid;
        msg->msg.socket->type = SILLY_SOCKET_ACCEPT;
        msg->msg.socket->data_size = 0;
        msg->msg.socket->data = NULL;

        silly_server_push(s->conn_buff[sid].workid, msg);

        //mesage handler will free it, so don't free it at here

        return ;
}

static void
_process(struct silly_socket *s)
{
        sp_event_t *e;
        struct conn *c;

        //printf("_process:%d,%d\n", s->event_index, s->event_cnt);

        int e_index = s->event_index++;

        e = &s->event_buff[e_index];
        c = (struct conn *)SP_UD(e);
        if (SP_ERR(e)) {
                fprintf(stderr, "_process:fd:%d occurs error now\n", c->fd);
                _socket_close(s, _conn_to_sid(s, c));
        } else if (SP_READ(e)) { 
                if (c->type == STYPE_LISTEN) {
                        int fd = accept(c->fd, NULL, 0);
                        if (fd >= 0) {
                                int err = _add_socket(s, fd, STYPE_SOCKET, c->workid);
                                if (err < 0) {
                                        fprintf(stderr, "_process:_add_socket fail:%d\n", errno);
                                        close(fd);
                                } else {        //now the err is sid(socket id)
                                        _report_accept(s, err);
                                }
                        }
                } else if (c->type == STYPE_SOCKET) {
                        _forward_msg(s, c);
                } else {
                        fprintf(stderr, "_process:EPOLLIN, unkonw client type:%d\n", c->type);
                }
        } else if (SP_WRITE(e)) {

        } else {
                fprintf(stderr, "_process: unhandler epoll event:\n");
        }
}


int silly_socket_run()
{
        struct silly_socket *s = SOCKET;
        if (s->event_index == s->event_cnt)
                _wait(s);
        else
                _process(s);

        return 0;
}

