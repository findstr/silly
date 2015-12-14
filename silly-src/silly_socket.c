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
#include <sys/select.h>

#include "socket_poll.h"
#include "silly_message.h"
#include "silly_server.h"
#include "silly_malloc.h"

#include "silly_socket.h"

//STYPE == socket type

#define ARRAY_SIZE(a)           (sizeof(a) / sizeof(a[0]))

#define EPOLL_EVENT_SIZE        100
#define MAX_CONN_COUNT          (1 << 16)
#define MIN_READBUFF_LEN        64

#define HASH(sid)               (sid % MAX_CONN_COUNT)

enum stype {
        STYPE_RESERVE,
        STYPE_LISTEN,           //listen fd
        STYPE_SOCKET,           //socket normal status
        STYPE_HALFCLOSE,        //socket is closed
        STYPE_CONNECTING,       //socket is connecting, if success it will be STYPE_SOCKET
        STYPE_CTRL,             //pipe cmd type
};

struct wlist {
        int size;
        int offset;
        uint8_t *buff;
        struct wlist    *next;
};

struct conn {
        int             fd;
        int             sid;
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
        fd_set                  ctrl_fdset;
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
                } ws;   //write socket  'W'
                struct {
                        char    ip[64];
                        int     port;
                        int     sid;
                } os;   //open socket   'O'
                struct {
                        int     sid;       
                } ks;   //kick(close) socket    'K'
        };
};

static struct silly_socket *SOCKET;

static void 
_init_conn_buff(struct silly_socket *s)
{
        int i;
        struct conn *c = s->conn_buff;
        for (i = 0; i < MAX_CONN_COUNT; i++) {
                c->sid = -1;
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
_fetch_conn(struct silly_socket *s, enum stype type)
{
        int i;
        int id;

        for (i = 0; i < MAX_CONN_COUNT; i++) {
                id = __sync_add_and_fetch(&s->reserve_sid, 1);
                if (id < 0) {
                        id = id & 0x7fffffff;
                        __sync_and_and_fetch(&s->reserve_sid, 0x7fffffff);
                }
                
                struct conn *c = &s->conn_buff[HASH(id)];
                if (c->type == STYPE_RESERVE) {
                        if (__sync_bool_compare_and_swap(&c->type, STYPE_RESERVE, type)) {
                                assert(c->wl_head.next == NULL);
                                assert(c->wl_tail == &c->wl_head);
                                assert(c->fd == -1);
                                c->alloc_size = MIN_READBUFF_LEN;
                                c->sid = id;
                                return c;
                        }
                }
        }

        return NULL;
}

static void
_wlist_free(struct conn *c)
{
        struct wlist *w;
        struct wlist *t;
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

static __inline int
_wlist_check_empty(struct conn *c)
{
        if (c->wl_head.next == NULL)
                return 1;
        else
                return 0;
}

static void
_free_conn(struct conn *c)
{
        assert(c->type != STYPE_RESERVE);
        _wlist_free(c);
        c->fd = -1;
        c->type =  STYPE_RESERVE;

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
        s->conn_buff = (struct conn *)silly_malloc(sizeof(struct conn) * MAX_CONN_COUNT);
        s->ctrl_conn = c;
        _init_conn_buff(s);
        FD_ZERO(&s->ctrl_fdset);

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
        int i;
        assert(SOCKET);
        close(SOCKET->sp_fd);
        close(SOCKET->ctrl_send_fd);
        close(SOCKET->ctrl_recv_fd);

        for (i = 0; i < MAX_CONN_COUNT; i++) {
                struct conn *c = &SOCKET->conn_buff[i];
                if (c->type == STYPE_SOCKET || c->type == STYPE_LISTEN || c->type == STYPE_HALFCLOSE)
                        close(c->fd);
        }

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
_add_socket(struct silly_socket *s, struct conn *c, int fd, int workid)
{
        int err;

        c->fd = fd;
        c->alloc_size = MIN_READBUFF_LEN;
        if (c->type == STYPE_LISTEN)               //listen is the special
                c->workid = workid;
        else
                c->workid = silly_server_balance(workid, c->sid);

        err = _sp_add(s->sp_fd, c->fd, c);
        return err;
}

static int
_fetch_and_add(struct silly_socket *s, int fd, enum stype type, int workid)
{
        int err;
        struct conn *c;

        c = _fetch_conn(s, type);
        if (c == NULL)
                return -1;

        err = _add_socket(s, c, fd, workid);
        if (err < 0) {
                _free_conn(c);
                return err;
        }

        return c->sid;
}

int silly_socket_listen(const char *ip, uint16_t port, int backlog, int workid)
{
        int err;
        int fd;
        int reuse;
        struct sockaddr_in addr;

        bzero(&addr, sizeof(addr));

        addr.sin_family = AF_INET;
        addr.sin_port = htons(port);
        inet_pton(AF_INET, ip, &addr.sin_addr);

        fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0)
                return -1;

        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));

        err = bind(fd, (struct sockaddr *)&addr, sizeof(addr));
        if (err < 0)
                goto end;

        _nonblock_it(fd);

        err = listen(fd, backlog);
        if (err < 0)
                goto end;
       
        err = _fetch_and_add(SOCKET, fd, STYPE_LISTEN, workid);
        if (err < 0) {
                close(fd);
                goto end;
        }
        return err;
end:
        close(fd);
        return -1;
}

static void
_report_socket_event(struct silly_socket *s, int sid, enum silly_message_type type, int portid)
{
        struct silly_message_socket *sm;
        struct silly_message *msg;
       
        msg =(struct silly_message *)silly_malloc(sizeof(*msg) + sizeof(*sm));
        msg->type = type;

        sm = (struct silly_message_socket *)(msg + 1);
        sm->sid = sid;
        sm->portid = portid;
        sm->data_size = 0;
        sm->data = NULL;

        silly_server_push(s->conn_buff[HASH(sid)].workid, msg);

        //mesage handler will free it, so don't free it at here
        return ;
}

static void
_clear_socket_event(struct silly_socket *s)
{
        int i;
        struct conn *c;
        sp_event_t *e;
 
        for (i = s->event_index; i < s->event_cnt; i++) {
                e = &s->event_buff[i];
                c = SP_UD(e);
                //after the _wait be called, this function can be more than once, so the c can be NULL
                if (c == NULL)
                        continue;
                if (c->type == STYPE_RESERVE)
                        SP_UD(e) = NULL;
        }

        return ;
}

static void
_close(struct silly_socket *s, struct conn *c)
{
        close(c->fd);
        _sp_del(s->sp_fd, c->fd);
        _free_conn(c);
        _clear_socket_event(s);

        return ;
}

//call _force_close only when read or send error
//because maybe the worker queue has this socket data, so the socket type only be the STYPE_CLOSE
//when call the silly_socket_close, this socket will be realy free
static void
_force_close(struct silly_socket *s, int sid)
{
        struct conn *c = &s->conn_buff[HASH(sid)];
        assert(c->sid == sid);
        if (c->sid != sid || c->type == STYPE_RESERVE) {
                fprintf(stderr, "_socket_close, error sid:%d - %d or error type:%d\n", c->sid, sid, c->type);
                return ;
        }

        _wlist_free(c);
        if (c->type != STYPE_HALFCLOSE)
                _report_socket_event(s, sid, SILLY_SOCKET_CLOSE, -1);
        _close(s, c);

        return ;
}

static int
_block_send_cmd(struct silly_socket *s, const struct cmd_packet *cmd)
{
        int err;
        for (;;) {
                err = write(s->ctrl_send_fd, cmd, sizeof(*cmd));
                if (err == sizeof(*cmd)) {
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

int silly_socket_connect(const char *addr, int port, int workid)
{
        int err;
        struct cmd_packet cmd;
        struct conn *c;

        c = _fetch_conn(SOCKET, STYPE_CONNECTING);
        if (c == NULL)
                return -1;
        c->workid = workid;
        cmd.op = 'O';
        strncpy(cmd.os.ip, addr, ARRAY_SIZE(cmd.os.ip));
        cmd.os.port = port;
        cmd.os.sid = c->sid;

        err = _block_send_cmd(SOCKET, &cmd);
        if (err < 0) {
                _free_conn(c);
                return err;
        }

        return c->sid;
}

int silly_socket_close(int sid)
{
        int err;
        struct cmd_packet cmd;
        struct conn *c = &SOCKET->conn_buff[HASH(sid)];
        if (c->sid != sid || c->type == STYPE_RESERVE || c->type == STYPE_HALFCLOSE)
                return -1;

        cmd.op = 'K';
        cmd.ks.sid = sid;

        err = _block_send_cmd(SOCKET, &cmd);

        return err;
}

int silly_socket_send(int sid, uint8_t *buff,  int size)
{
        int err;
        assert(sid >= 0);
        struct conn *c = &SOCKET->conn_buff[HASH(sid)];
        struct cmd_packet cmd;

        if (c->sid != sid || c->type != STYPE_SOCKET) {
                silly_free(buff);               
                return -1;
        }

        cmd.op = 'W';
        cmd.ws.sid = sid;
        cmd.ws.size = size;
        cmd.ws.buff = buff;

        err = _block_send_cmd(SOCKET, &cmd);

        return err;
}

int silly_socket_terminate()
{
        int err;
        struct cmd_packet cmd;
        
        cmd.op = 'T';
        err = _block_send_cmd(SOCKET, &cmd);

        return err;
}

static int
_forward_msg(struct silly_socket *s, struct conn *c)
{
        int err;
        int len;
        uint8_t *buff = (uint8_t *)silly_malloc(c->alloc_size);
        
        err = 0;

        len = recv(c->fd, buff, c->alloc_size, 0);
        if (len < 0) {
                silly_free(buff);
                switch (errno) {
                case EINTR:
                        fprintf(stderr, "_forward_msg, EINTR\n");
                        break;
                case EAGAIN:
                        fprintf(stderr, "_forward_msg, EAGAIN\n");
                        break;
                default:
                        fprintf(stderr, "_forward_msg, %s\n", strerror(errno));
                        _force_close(s, c->sid);
                        err = -1;
                        break;
                }
        } else if (len == 0) {
                silly_free(buff);
                _force_close(s, c->sid);
                err = -1;
        } else {
                assert(c->workid >= 0);
                struct silly_message_socket *sm;
                struct silly_message *msg;
                
                msg = (struct silly_message *)silly_malloc(sizeof(*msg) + sizeof(*sm));
                msg->type = SILLY_SOCKET_DATA;
                
                sm = (struct silly_message_socket *)(msg + 1);
                sm->sid = c->sid;
                sm->data_size = len;
                sm->data = buff;
                
                silly_server_push(c->workid, msg);         

                //to predict the pakcet size
                if (len == c->alloc_size)
                        c->alloc_size *= 2;
                else if (len < c->alloc_size && c->alloc_size > MIN_READBUFF_LEN)
                        c->alloc_size = (len / MIN_READBUFF_LEN + 1) * MIN_READBUFF_LEN;
        
        }

        return err;
}

static void
_wlist_append(struct conn *c, uint8_t *buff, int offset, int size)
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
_try_connect(struct silly_socket *s, int sid, const char *ip, int port)
{
        int err;
        int fd;
        struct sockaddr_in      addr;
        struct conn *c =  &s->conn_buff[HASH(sid)];

        addr.sin_family = AF_INET;
        addr.sin_port = htons(port);
        inet_pton(AF_INET, ip, &addr.sin_addr);

        fd = socket(AF_INET, SOCK_STREAM, 0);
        err = connect(fd, (struct sockaddr *)&addr, sizeof(addr));
        if (err == 0)
                err = _add_socket(s, c, fd, c->workid);

        if (err >= 0) {//now the err contain the sid
                c->type = STYPE_SOCKET;
                _report_socket_event(s, sid, SILLY_SOCKET_CONNECTED, -1);
        } else {
                _report_socket_event(s, sid, SILLY_SOCKET_CLOSE, -1);
                close(fd);
                _free_conn(c);
                fprintf(stderr, "_try_connect:ip:%s, errno:%d\n", ip, errno);
        }
        return ;
}

static void
_try_close(struct silly_socket *s, int sid)
{
        struct conn *c = &s->conn_buff[HASH(sid)];
        if (c->sid != sid || c->type == STYPE_RESERVE) {
                fprintf(stderr, "_try_close, error sid:%d - %d or error type:%d\n", c->sid, sid, c->type);
                return ;
        }
 
        if (_wlist_check_empty(c)) //already send all the data, directly close it
                _close(s, c);
        else
                c->type = STYPE_HALFCLOSE;

        return ;
}

static void
_try_send(struct silly_socket *s, int sid, uint8_t *buff, int size)
{
        struct conn *c = &s->conn_buff[HASH(sid)];
        struct wlist *w;

        if (c->sid != sid || c->type != STYPE_SOCKET) {
                silly_free(buff);
                return ;
        }
        assert(c->type == STYPE_SOCKET);
        w = c->wl_head.next;
        if (w == NULL) {        //write list empty, then try send
                int err = send(c->fd, buff, size, 0);
                if ((err == -1 && errno != EAGAIN && errno != EINTR) || err == 0) {
                        silly_free(buff);
                        _force_close(s, sid);
                        return ;
                }
                if (err == -1)  //EINTR, EAGAIN means send no data
                        err = 0;
                if (err == size) {      //send ok
                        silly_free(buff);
                        return ;
                }
                assert(err >= 0);
                _wlist_append(c, buff, err, size - err);
                _sp_write_enable(s->sp_fd, c->fd, c, 1);
        } else {
                _wlist_append(c, buff, 0, size);
        }

        return ;
}

static void
_read_pipe_block(int fd, uint8_t *buff, int size)
{
       for (;;) {
                int err = read(fd, buff, size);
                if (err == -1) {
                        if (errno == EINTR)
                                continue;
                        fprintf(stderr, "_ctrl_cmd:occurs error:%d\n", err);
                        return ;
                }
                assert(err == size);
                return ;
        }
}

static int _has_cmd(struct silly_socket *s)
{
        int ret;
        struct timeval tv = {0, 0};

        FD_SET(s->ctrl_recv_fd, &s->ctrl_fdset);
        ret = select(s->ctrl_recv_fd + 1, &s->ctrl_fdset, NULL, NULL, &tv);
        if (ret == 1)
                return 1;
        
        return 0;
}

/* At first , I worry about always has data come into the ctrl_recv_fd pipe,
 * when _ctrl_cmd processing the last the command,
 * but after days, I don't worry about it.
 * Because when occurs this condition, only one reason, the system overload,
 * we need to adjust the max connection count
 */

static void
_ctrl_cmd(struct silly_socket *s)
{
        struct cmd_packet cmd;
        while (_has_cmd(s)) {
                _read_pipe_block(s->ctrl_recv_fd, (uint8_t *)&cmd, sizeof(cmd));
                switch (cmd.op) {
                case 'W':
                        _try_send(s, cmd.ws.sid, cmd.ws.buff, cmd.ws.size);
                        break;
                case 'O':
                        _try_connect(s, cmd.os.sid, cmd.os.ip, cmd.os.port);
                        break;
                case 'K':
                        _try_close(s, cmd.ks.sid);
                        break;
                case 'T':       //just to return from sp_wait
                        break;
                default:
                        fprintf(stderr, "_ctrl_cmd:unkonw operation:%d\n", cmd.op);
                        assert(!"oh, no!");
                        break;
                }
        }

        return ;
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

static int
_wait(struct silly_socket *s)
{
        s->event_cnt = _sp_wait(s->sp_fd, s->event_buff, EPOLL_EVENT_SIZE);
        if (s->event_cnt == -1) {
                s->event_index = 0;
                s->event_cnt = 0;
                fprintf(stderr, "silly_socket:_wait fail:%d\n", errno);
                return -1;
        }
        s->event_index = 0;
        _ctrl_cmd(s);

        return 0;
}



int silly_socket_poll()
{
        int err;
        sp_event_t *e;
        struct conn *c;
        struct silly_socket *s = SOCKET;
        if (_wait(s) == -1)
                return 0;

        while (s->event_index < s->event_cnt) {
                int e_index = s->event_index++;
                //printf("_process:%d,%d\n", s->event_index, s->event_cnt);

                e = &s->event_buff[e_index];
                c = (struct conn *)SP_UD(e);
                if (c == NULL)          //the socket event has be cleared
                        continue;

                if (SP_ERR(e)) {
                        fprintf(stderr, "_process:fd:%d occurs error now\n", c->fd);
                        _force_close(s, c->sid);
                        continue;
                }
                if (SP_READ(e)) { 
                        err = 0;
                        if (c->type == STYPE_LISTEN) {
                                int fd = accept(c->fd, NULL, 0);
                                if (fd >= 0) {
                                        err = _fetch_and_add(s, fd, STYPE_SOCKET, c->workid);
                                        if (err < 0) {
                                                fprintf(stderr, "_process:_add_socket fail:%d\n", errno);
                                                close(fd);
                                                err = -1;
                                        } else {        //now the err is sid(socket id)
                                                _report_socket_event(s, err, SILLY_SOCKET_ACCEPT, c->sid);
                                        }
                                } else {
                                        err = -1;
                                }
                        } else if (c->type == STYPE_SOCKET) {
                                err = _forward_msg(s, c);
                        } else if (c->type != STYPE_CTRL) {
                                err = -1;
                                fprintf(stderr, "_process:EPOLLIN, unkonw client type:%d\n", c->type);
                        }

                        if (err < 0)            //this socket have already occurs error, so ignore the write event
                                continue;
                }
                if (SP_WRITE(e)) {
                        struct wlist *w;
                        w = c->wl_head.next;
                        assert(w);
                        while (w) {
                                int err = _send(s, c, w->buff + w->offset, w->size);
                                if (err == -1) {
                                        _force_close(s, c->sid);
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

                        if (w == NULL && c->type == STYPE_HALFCLOSE)
                                _close(s, c);
                }
        }

        return 0;
}

