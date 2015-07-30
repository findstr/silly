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

struct wlist {
        int size;
        int offset;
        uint8_t *buff;
        struct wlist    *next;
};

struct conn {
        int             fd;
        enum stype      type;
        int             alloc_size;
        int             workid;
        struct wlist    wl_head;
        struct wlist    *wl_tail;
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

struct cmd_packet {      //for reduce the system call, waste some memory
        int     op;
        union {
                struct {
                        int     sid;
                        int     size;
                        uint8_t *buff;
                } ws;
        };
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
                c->wl_head.next = NULL;
                c->wl_tail = &c->wl_head;
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
                                assert(c->wl_head.next == NULL);
                                assert(c->wl_tail == &c->wl_head);
                                return c;
                        }
                }
        }

        return NULL;
}

static void
_release_conn(struct conn *c)
{
        struct wlist *w;
        struct wlist *t;

        c->type = STYPE_RESERVE;

        w = c->wl_head.next;
        while (w) {
                t = w;
                w = w->next;

                assert(t->buff);
                silly_free(t->buff);
                silly_free(t);
        }

        c->wl_head.next = NULL;
        c->wl_tail = &c->wl_head;

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

        err = pipe(fd); //use the pipe and not the socketpair because the pipe will be automatic when the data size small than BUFF_SIZE
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
        struct silly_message_socket *sm;
        struct silly_message *msg;
        
        msg = (struct silly_message *)silly_malloc(sizeof(*msg) + sizeof(*sm));
        msg->type = SILLY_SOCKET_CLOSE;

        sm = (struct silly_message_socket *)(msg + 1);
        sm->sid = sid;
        sm->data_size = 0;
        sm->data = NULL;

        silly_server_push(s->conn_buff[sid].workid, msg);
}

static void
_clear_socket_event(struct silly_socket *s, struct conn *c)
{
        sp_event_t *e;
 
        for (int i = s->event_index; i < s->event_cnt; i++) {
                e = &s->event_buff[i];
                if (SP_UD(e) == c)
                        SP_CLR(e);
        }

        return ;
}

static void
_socket_close(struct silly_socket *s, int sid)
{
        struct conn *c = &s->conn_buff[sid];
        close(c->fd);
        _report_close(s, sid);
        _clear_socket_event(s, c);
        _remove_socket(s, sid);

        return ;
}

void silly_socket_kick(int sid)
{
        //need async for epoll/kevent
        return ;
}

int silly_socket_send(int sid, uint8_t *buff,  int size)
{
        int err;
        assert(sid >= 0);
        struct cmd_packet cmd;

        cmd.op = 'W';
        cmd.ws.sid = sid;
        cmd.ws.size = size;
        cmd.ws.buff = buff;

        for (;;) {
                err = write(SOCKET->ctrl_send_fd, &cmd, sizeof(cmd));
                if (err == sizeof(cmd)) {
                        break;
                } else if (err == -1 && errno == EINTR) {       //will be automatic, so errno can not be EAGAIN
                        continue;
                } else {
                        fprintf(stderr, "silly_socket_send: the pipe fd occurs error\n");
                        assert(0);
                        return -1;
                }
        }

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
                struct silly_message_socket *sm;
                struct silly_message *msg;
                
                msg = (struct silly_message *)silly_malloc(sizeof(*msg) + sizeof(*sm));
                msg->type = SILLY_SOCKET_DATA;
                
                sm = (struct silly_message_socket *)(msg + 1);
                sm->sid = _conn_to_sid(s, c);
                sm->data_size = len;
                sm->data = buff;
                
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
        struct silly_message_socket *sm;
        struct silly_message *msg;
       
        msg =(struct silly_message *)silly_malloc(sizeof(*msg) + sizeof(*sm));
        msg->type = SILLY_SOCKET_ACCEPT;

        sm = (struct silly_message_socket *)(msg + 1);
        sm->sid = sid;
        sm->data_size = 0;
        sm->data = NULL;

        silly_server_push(s->conn_buff[sid].workid, msg);

        //mesage handler will free it, so don't free it at here

        return ;
}

static void
_append_wlist(struct conn *c, uint8_t *buff, int offset, int size)
{
        struct wlist *w;
        w = (struct wlist *)silly_malloc(sizeof(*w));
        w->offset = offset;
        w->size = size;
        w->buff = buff;
        w->next = NULL;

        c->wl_tail->next = w;
        c->wl_tail = w;
        
        return ;
}

static void
_try_send(struct silly_socket *s, int sid, uint8_t *buff, int size)
{
        assert(sid < MAX_CONN);
        struct conn *c = &s->conn_buff[sid];
        struct wlist *w;

        if (c->type == STYPE_RESERVE) {
                silly_free(buff);
                return ;
        }

        assert(c->type == STYPE_SOCKET);

        w = c->wl_head.next;
        if (w == NULL) {        //write list empty, then try send
                int err = send(c->fd, buff, size, 0);
                if ((err == -1 && errno != EAGAIN && errno != EINTR) || err == 0) {
                        silly_free(buff);
                        _socket_close(s, sid);
                        return ;
                }

                if (err == -1)  //EINTR, EAGAIN means send no data
                        err = 0;

                if (err == size) {      //send ok
                        silly_free(buff);
                        return ;
                }
                assert(err >= 0);
                _append_wlist(c, buff, err, size - err);
                _sp_write_enable(s->sp_fd, c->fd, c, 1);
        } else {
                _append_wlist(c, buff, 0, size);
        }

        return ;
}

static void
_ctrl_cmd(struct silly_socket *s, struct conn *c)
{
        int err;
        struct cmd_packet cmd;

        for (;;) {
                err = read(c->fd, &cmd, sizeof(cmd));
                if (err == sizeof(cmd)) {
                        break;
                } else if (err == -1 && errno == EINTR){
                        continue;
                } else {
                        fprintf(stderr, "_ctrl_cmd:occurs error:%d\n", err);
                        return ;
                }
        }

        switch (cmd.op) {
        case 'W':
                _try_send(s, cmd.ws.sid, cmd.ws.buff, cmd.ws.size);
                break;
        default:
                fprintf(stderr, "_ctrl_cmd:unkonw operation:%d\n", cmd.op);
                assert(!"oh, no!");
                break;
        }
}


static int
_send(struct silly_socket *s, struct conn *c, uint8_t *buff, int size)
{
        int err;
        for (;;) {
                err = send(c->fd, buff, size, 0);
                if (err == 0) {
                        return -1;
                } else if (err == -1 && (errno == EINTR || errno == EAGAIN)) {
                        continue;
                } else {
                        assert(err > 0);
                        return err;
                }
        }

        assert(!"never come here");
        return 0;
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
                } else if (c->type == STYPE_CTRL) {
                        _ctrl_cmd(s, c);
                } else {
                        fprintf(stderr, "_process:EPOLLIN, unkonw client type:%d\n", c->type);
                }
        } else if (SP_WRITE(e)) {
                struct wlist *w;
                w = c->wl_head.next;
                assert(w);
                while (w) {
                        int err = _send(s, c, w->buff + w->offset, w->size);
                        if (err == -1) {
                                _socket_close(s, _conn_to_sid(s, c));
                                break;
                        }
                        
                        if (err < w->size) {    //send some
                                w->size -= err;
                                w->offset += err;
                                break;
                        }

                        assert(err == w->size); //send one complete
                        c->wl_head.next = w->next;

                        silly_free(w->buff);
                        silly_free(w);

                        w = c->wl_head.next;
                }

                if (w == NULL) {
                        c->wl_tail = &c->wl_head;
                        _sp_write_enable(s->sp_fd, c->fd, c, 0);
                }

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

