#include <assert.h>
#include <stdio.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <netdb.h>
#include <arpa/inet.h>
#include <netinet/tcp.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/select.h>

#include "silly.h"
#include "socket_poll.h"
#include "silly_worker.h"
#include "silly_malloc.h"

#include "silly_socket.h"

//STYPE == socket type

#if EAGAIN == EWOULDBLOCK
#define ETRYAGAIN EAGAIN
#else
#define ETRYAGAIN EAGAIN: case EWOULDBLOCK
#endif

#define ARRAY_SIZE(a)           (sizeof(a) / sizeof(a[0]))
#define EVENT_SIZE              128
#define MAX_SOCKET_COUNT        (1 << 16)       //65536
#define MIN_READBUFF_LEN        64
#define HASH(sid)               (sid % MAX_SOCKET_COUNT)

enum stype {
        STYPE_RESERVE,
        STYPE_ALLOCED,
        STYPE_LISTEN,           //listen fd
        STYPE_SOCKET,           //socket normal status
        STYPE_HALFCLOSE,        //socket is closed
        STYPE_CONNECTING,       //socket is connecting, if success it will be STYPE_SOCKET
        STYPE_CTRL,             //pipe cmd type
};

struct wlist {
        size_t offset;
        size_t size;
        uint8_t *buff;
        struct wlist    *next;
};

struct socket {
        int             sid;     //socket descriptor
        int             fd;
        enum stype      type;
        int             presize;
        struct wlist    wlhead;
        struct wlist    *wltail;
};

struct silly_socket {
        int             spfd;
        size_t          eventcap;
        //event
        sp_event_t      *eventbuff;
        int             eventindex;
        int             eventcount;
        //socket pool
        struct socket   *socketpool;
        //ctrl pipe, call write can be automatic wen data less then 64k(from APUE)
        int             ctrlsendfd;
        int             ctrlrecvfd;
        fd_set          ctrlfdset;
        //reserve id(for socket fd remap)
        int             reserveid;
};

static struct silly_socket *SSOCKET;

static void 
socketpool_init(struct silly_socket *ss)
{
        int i;
        struct socket *pool = silly_malloc(sizeof(*pool) * MAX_SOCKET_COUNT);
        ss->socketpool = pool;
        ss->reserveid = -1;
        for (i = 0; i < MAX_SOCKET_COUNT; i++) {
                pool->sid = -1;
                pool->fd = -1;
                pool->type = STYPE_RESERVE;
                pool->presize = MIN_READBUFF_LEN;
                pool->wlhead.next = NULL;
                pool->wltail = &pool->wlhead;
                pool++;
        }
        return ;
}

static struct socket*
allocsocket(struct silly_socket *ss, enum stype type)
{
        int i;
        int id;
        for (i = 0; i < MAX_SOCKET_COUNT; i++) {
                id = __sync_add_and_fetch(&ss->reserveid, 1);
                if (id < 0) {
                        id = id & 0x7fffffff;
                        __sync_and_and_fetch(&ss->reserveid, 0x7fffffff);
                }
                
                struct socket *s = &ss->socketpool[HASH(id)];
                if (s->type == STYPE_RESERVE) {
                        if (__sync_bool_compare_and_swap(&s->type, STYPE_RESERVE, type)) {
                                assert(s->wlhead.next == NULL);
                                assert(s->wltail == &s->wlhead);
                                s->presize = MIN_READBUFF_LEN;
                                s->sid = id;
                                return s;
                        }
                }
        }
        fprintf(stderr, "allocsocket fail, find no empty entry\n");
        return NULL;
}

static __inline void
freesocket(struct silly_socket *ss, struct socket *s)
{
        (void)ss;
        assert(s->wlhead.next == NULL);
        s->type = STYPE_RESERVE;
}

static void
wlist_append(struct socket *s, uint8_t *buff, size_t offset, size_t size)
{
        struct wlist *w;
        w = (struct wlist *)silly_malloc(sizeof(*w));
        w->offset = offset;
        w->size = size;
        w->buff = buff;
        w->next = NULL;
        s->wltail->next = w;
        s->wltail = w;
        return ;
}

static void
wlist_free(struct socket *s)
{
        struct wlist *w;
        struct wlist *t;
        w = s->wlhead.next;
        while (w) {
                t = w;
                w = w->next;
                assert(t->buff);
                silly_free(t->buff);
                silly_free(t);
        }
        s->wlhead.next = NULL;
        s->wltail = &s->wlhead;
        return ;
}
static inline int
wlist_empty(struct socket *s)
{
        return s->wlhead.next == NULL ? 1 : 0;
}

static struct socket *
newsocket(struct silly_socket *ss, struct socket *s, int fd, enum stype type)
{
        int err;
        if (s == NULL)
                s = allocsocket(ss, type);
        if (s == NULL) {
                close(fd);
                return NULL;
        }
        assert(s->type == type || s->type == STYPE_ALLOCED);
        assert(s->presize == MIN_READBUFF_LEN);
        s->fd = fd;
        s->type = type;
        err = sp_add(ss->spfd, fd, s);
        if (err < 0) {
                perror("newsocket");
                close(fd);
                freesocket(ss, s);
                return NULL;
        }
        return s;
}

static void
delsocket(struct silly_socket *ss, struct socket *s)
{
        if (s->type == STYPE_RESERVE) {
                const char *fmt = "delsocket sid:%d error type:%d\n";
                fprintf(stderr, fmt, s->sid, s->type);
                return ;
        }
        wlist_free(s);
        sp_del(ss->spfd, s->fd);
        close(s->fd);
        freesocket(ss, s);
        return ;
}

static void
clear_socket_event(struct silly_socket *ss)
{
        int i;
        struct socket *s;
        sp_event_t *e;
        for (i = ss->eventindex; i < ss->eventcount; i++) {
                e = &ss->eventbuff[i];
                s = SP_UD(e);
                if (s == NULL)
                        continue;
                if (s->type == STYPE_RESERVE)
                        SP_UD(e) = NULL;
        }
        return ;
}

static void
nonblock(int fd)
{
        int err;
        int flag;
        flag = fcntl(fd, F_GETFL, 0);
        if (flag < 0) {
                perror("nonblock F_GETFL");
                return ;
        }
        flag |= O_NONBLOCK;
        err = fcntl(fd, F_SETFL, flag);
        if (err < 0) {
                perror("nonblock F_SETFL");
                return ;
        }
        return ;
}

static void
nodelay(int fd)
{
        int err;
        int on = 1;
        err = setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, sizeof(on));
        if (err < 0)
                perror("nodelay fail");
}

static void
keepalive(int fd)
{
        int err;
        int on = 1;
        err = setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &on, sizeof(on));
        if (err < 0)
                perror("keepalive fail");
}

#define ADDRLEN (64)
static void
report_accept(struct silly_socket *ss, struct socket *listen)
{
        const char *str;
        struct socket *s;
        struct sockaddr_in addr;
        struct silly_message_socket *sa;
        char buff[INET_ADDRSTRLEN];
        assert(ADDRLEN >= INET_ADDRSTRLEN + 8);
        socklen_t len = sizeof(struct sockaddr);
        int fd = accept(listen->fd, (struct sockaddr *)&addr, &len);
        if (fd < 0)
                return ;
        sa = silly_malloc(sizeof(*sa) + ADDRLEN);
        sa->data = (uint8_t *)(sa + 1);
        sa->type = SILLY_SACCEPT;
        str = inet_ntop(addr.sin_family, &addr.sin_addr, buff, sizeof(buff));
        snprintf((char *)sa->data, ADDRLEN, "%s:%d", str, ntohs(addr.sin_port));
        nonblock(fd);
        keepalive(fd);
        nodelay(fd);
        s = newsocket(ss, NULL, fd, STYPE_SOCKET);
        if (s == NULL)
                return;
        sa->sid = s->sid;
        sa->ud = listen->sid;
        silly_worker_push(tocommon(sa));         
        return ;
}

static void
report_close(struct silly_socket *ss, struct socket *s)
{
        (void)ss;
        if (s->type == STYPE_HALFCLOSE)//don't notify the active close
                return ;
        assert(s->type == STYPE_SOCKET || s->type == STYPE_RESERVE);
        struct silly_message_socket *sc = silly_malloc(sizeof(*sc));
        sc->type = SILLY_SCLOSE;
        sc->sid = s->sid;
        sc->ud = 0;
        silly_worker_push(tocommon(sc));
        return ;
}

static void
report_data(struct silly_socket *ss, struct socket *s, uint8_t *data, size_t sz)
{
        (void)ss;
        assert(s->type == STYPE_SOCKET);
        struct silly_message_socket *sd = silly_malloc(sizeof(*sd));
        sd->type = SILLY_SDATA;
        sd->sid = s->sid;
        sd->ud = sz;
        sd->data = data;
        silly_worker_push(tocommon(sd));
        return ;
};

static void
report_error(struct silly_socket *ss, struct socket *s, int err)
{
        (void)ss;
        int or = s->type == STYPE_LISTEN ? 1 : 0;
        or += s->type == STYPE_SOCKET ? 1 : 0;
        or += s->type == STYPE_CONNECTING ? 1 : 0;
        assert(or > 0);
        struct silly_message_socket *se = silly_malloc(sizeof(*se));
        se->type = SILLY_SCLOSE;
        se->sid = s->sid;
        se->ud = err;
        silly_worker_push(tocommon(se));
        return ;
}

static __inline int
checkconnected(int fd)
{
        int ret;
        int err;
        socklen_t errlen = sizeof(err);
        ret = getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &errlen);
        if (ret < 0) {
                perror("checkconnected");
                return ret;
        }
        if (err != 0) {
                errno = err;
                fprintf(stderr, "checkconnected:%d\n", err);
                return -1;
        }
        return 0;
}

static void
report_connected(struct silly_socket *ss, struct socket *s)
{
        int err;
        err = checkconnected(s->fd);
        if (err < 0) {  //check ok
                report_error(ss, s, errno);
                delsocket(ss, s);
                return ;
        }
        struct silly_message_socket *sc = silly_malloc(sizeof(*sc));
        sc->type = SILLY_SCONNECTED;
        sc->sid = s->sid;
        if (wlist_empty(s))
                sp_write_enable(ss->spfd, s->fd, s, 0);
        silly_worker_push(tocommon(sc));
        return ;
}

static ssize_t
readn(int fd, uint8_t *buff, size_t sz)
{
        for (;;) {
                ssize_t len;
                len = read(fd, buff, sz);
                if (len < 0) {
                        switch(errno) {
                        case EINTR:
                                fprintf(stderr, "readn:%d, EINTR\n", fd);
                                continue;
                        case ETRYAGAIN:
                                fprintf(stderr, "readn:%d, EAGAIN\n", fd);
                                return 0;
                        default:
                                fprintf(stderr, "readn:%d, %s\n", fd, strerror(errno));
                                return -1;
                        }
                } else if (len == 0) {
                        return -1;
                }
                return len;
        }
        assert(!"expected return of readn");
        return 0;
}

static ssize_t
sendn(int fd, const uint8_t *buff, size_t sz)
{
        for (;;) {
                ssize_t len;
                len = write(fd, buff, sz);
                assert(len != 0);
                if (len == -1) {
                        switch (errno) {
                        case EINTR:
                                fprintf(stderr, "sendn:%d, EINTR\n", fd);
                                continue;
                        case ETRYAGAIN:
                                fprintf(stderr, "sendn:%d, EAGAIN\n", fd);
                                return 0;
                        default:
                                fprintf(stderr, "sendn:%d, %s\n", fd, strerror(errno));
                                return -1;
                        }
                }
                return len;
        }
        assert(!"never come here");
        return 0;
}

static int
forward_msg(struct silly_socket *ss, struct socket *s)
{
        ssize_t sz;
        uint8_t *buff = (uint8_t *)silly_malloc(s->presize);
        sz = readn(s->fd, buff, s->presize);
        //half close socket need no data
        if (sz > 0 && s->type != STYPE_HALFCLOSE) {
                report_data(ss, s, buff, sz);
                //to predict the pakcet size
                if (sz == s->presize)
                        s->presize *= 2;
        } else {
                silly_free(buff);
                if (sz < 0) {
                        report_close(ss, s);
                        delsocket(ss, s);
                        return -1;
                }
                return 0;
        }
        return sz;
}

static void
send_msg(struct silly_socket *ss, struct socket *s)
{
        struct wlist *w;
        w = s->wlhead.next;
        assert(w);
        while (w) {
                ssize_t sz;
                sz = sendn(s->fd, w->buff + w->offset, w->size);
                if (sz < 0) {
                        report_close(ss, s);
                        delsocket(ss, s);
                        return ;
                }
                if (sz < w->size) {//send some
                        w->size -= sz;
                        w->offset += sz;
                        return ;
                }
                assert(sz == w->size);
                s->wlhead.next = w->next;
                silly_free(w->buff);
                silly_free(w);
                w = s->wlhead.next;
                if (w == NULL) {//send ok
                        s->wltail = &s->wlhead;
                        sp_write_enable(ss->spfd, s->fd, s, 0);
                        if (s->type == STYPE_HALFCLOSE)
                                delsocket(ss, s);
                }
        }
        return ;
}
static int 
hascmd(struct silly_socket *ss)
{
        int ret;
        struct timeval tv = {0, 0};
        FD_SET(ss->ctrlrecvfd, &ss->ctrlfdset);
        ret = select(ss->ctrlrecvfd + 1, &ss->ctrlfdset, NULL, NULL, &tv);
        return ret == 1 ? 1 : 0;
}

//for read one complete packet once system call, fix the packet length
struct cmdpacket {
        int     type;
        union {
                char dummy[128];
                struct {
                        int sid;
                } listen;
                struct {
                        char ip[64];
                        int  port;
                        int sid;
                } connect;
                struct {
                        int sid;
                } close;
                struct {
                        int     sid;
                        ssize_t size;
                        uint8_t *data;
                } send;
        } u;
};

static int
pipe_blockread(int fd, struct cmdpacket *pk)
{
        for (;;) {
                ssize_t err = read(fd, pk, sizeof(*pk));
                if (err == -1) {
                        if (errno  == EINTR)
                                continue;
                        perror("pip_blockread");
                        return -1;
                }
                assert(err == sizeof(*pk));
                return 0;
        }
        return 0;
}

static int
pipe_blockwrite(int fd, struct cmdpacket *pk)
{
        for (;;) {
                ssize_t err = write(fd, pk, sizeof(*pk));
                if (err == -1) {
                        if (errno == EINTR)
                                continue;
                        perror("pipe_blockwrite");
                        return -1;
                }
                assert(err == sizeof(*pk));
                return 0;
        }
        return 0;
}

static int
dolisten(const char *ip, uint16_t port, int backlog)
{
        int err;
        int fd;
        int reuse = 1;
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
        nonblock(fd);
        err = listen(fd, backlog);
        if (err < 0)
                goto end;
        return fd;
end:
        perror("dolisten");
        close(fd);
        return -1;

}

int 
silly_socket_listen(const char *ip, uint16_t port, int backlog)
{
        int fd;
        struct socket *s;
        struct cmdpacket cmd;
        fd = dolisten(ip, port, backlog);
        if (fd < 0)
                return fd;
        s = allocsocket(SSOCKET, STYPE_ALLOCED);
        if (s == NULL) {
                fprintf(stderr, "listen %s:%d:%d allocsocket fail\n", ip, port, backlog);
                close(fd);
                return -1;
        }

        s->fd = fd;
        cmd.type = 'L';
        cmd.u.listen.sid = s->sid;
        pipe_blockwrite(SSOCKET->ctrlsendfd, &cmd);
        return s->sid;
}

static int
trylisten(struct silly_socket *ss, struct cmdpacket *cmd)
{
        int sid = cmd->u.listen.sid;
        struct socket *s = &ss->socketpool[HASH(sid)];
        assert(s->sid == sid);
        assert(s->type == STYPE_ALLOCED);
        int err = sp_add(ss->spfd, s->fd, s);
        if (err < 0) {
                perror("trylisten");
                report_error(ss, s, errno);
                close(s->fd);
                freesocket(ss, s);
        }
        s->type = STYPE_LISTEN;
        return err;
}

int 
silly_socket_connect(const char *addr, int port)
{
        size_t sz;
        struct cmdpacket cmd;
        struct socket *s;
        s = allocsocket(SSOCKET, STYPE_ALLOCED);
        if (s == NULL)
                return -1;
        cmd.type = 'C';
        sz = ARRAY_SIZE(cmd.u.connect.ip) - 1;
        strncpy(cmd.u.connect.ip, addr, sz);
        cmd.u.connect.ip[sz] = '\0';
        cmd.u.connect.port = port;
        cmd.u.connect.sid = s->sid;
        pipe_blockwrite(SSOCKET->ctrlsendfd, &cmd);
        return s->sid;
}

static void
tryconnect(struct silly_socket *ss, struct cmdpacket *cmd)
{
        int err;
        int fd;
        struct sockaddr_in      addr;
        int sid = cmd->u.connect.sid;
        int port = cmd->u.connect.port;
        const char *ip = cmd->u.connect.ip;
        struct socket *s =  &ss->socketpool[HASH(sid)];
        assert(s->sid == sid);
        assert(s->type == STYPE_ALLOCED);
        addr.sin_family = AF_INET;
        addr.sin_port = htons(port);
        inet_pton(AF_INET, ip, &addr.sin_addr);
        fd = socket(AF_INET, SOCK_STREAM, 0);
        assert(fd >= 0);
        nonblock(fd);
        keepalive(fd);
        nodelay(fd);
        err = connect(fd, (struct sockaddr *)&addr, sizeof(addr));
        if (err == -1 && errno != EINPROGRESS) {        //error
                const char *fmt = "tryconnect:ip:%s:%d,errno:%d\n";
                fprintf(stderr, fmt, ip, port, errno);
                report_error(ss, s, errno);
                freesocket(ss, s);
                return ;
        } else if (err == 0) {  //connect
                s = newsocket(ss, s, fd, STYPE_SOCKET);
                if (s == NULL)
                        report_close(ss, s);
                else 
                        report_connected(ss, s);
                return ;
        } else {        //block
                s = newsocket(ss, s, fd, STYPE_CONNECTING);
                if (s == NULL)
                        report_close(ss, s);
                else
                        sp_write_enable(ss->spfd, s->fd, s, 1);
        }
}

static __inline struct socket *
checksocket(struct silly_socket *ss, int sid)
{
        struct socket *s = &SSOCKET->socketpool[HASH(sid)];
        if (s->sid != sid)
                return NULL;
        switch (s->type) {
        case STYPE_LISTEN:
        case STYPE_SOCKET:
                return s;
        default:
                return NULL;
        }
        return NULL;
}

int 
silly_socket_close(int sid)
{
        struct cmdpacket cmd;
        struct socket *s = checksocket(SSOCKET, sid);
        if (s == NULL)
                return -1;
        cmd.type = 'K';
        cmd.u.close.sid = sid;
        pipe_blockwrite(SSOCKET->ctrlsendfd, &cmd);
        return 0;
}

static int
tryclose(struct silly_socket *ss, struct cmdpacket *cmd)
{
        struct socket *s = checksocket(ss, cmd->u.close.sid);
        if (s == NULL)
                return -1;
        if (wlist_empty(s)) { //already send all the data, directly close it
                delsocket(ss, s);
                return 0;
        } else {
                s->type = STYPE_HALFCLOSE;
                return -1;
        }
}

int
silly_socket_send(int sid, uint8_t *buff,  size_t sz)
{
        struct cmdpacket cmd;
        struct socket *s = checksocket(SSOCKET, sid);
        if (s == NULL) {
                silly_free(buff);
                return -1;
        }
        if (sz == 0) {
                silly_free(buff);
                return -1;
        }
        cmd.type = 'S';
        cmd.u.send.sid = sid;
        cmd.u.send.data = buff;
        cmd.u.send.size = sz;
        pipe_blockwrite(SSOCKET->ctrlsendfd, &cmd);
        return 0;
}

static int
trysend(struct silly_socket *ss, struct cmdpacket *cmd)
{
        struct socket *s = checksocket(ss, cmd->u.send.sid);
        uint8_t *data = cmd->u.send.data;
        size_t sz = cmd->u.send.size;
        if (s == NULL) {
                silly_free(cmd->u.send.data);
                return 0;
        }
        if (wlist_empty(s)) {//try send
                ssize_t n = sendn(s->fd, data, sz);
                if (n < 0) {
                        silly_free(data);
                        report_close(ss, s);
                        delsocket(ss, s);
                        return -1;
                } else if (n < sz) {
                        wlist_append(s, data, n, sz);
                        sp_write_enable(ss->spfd, s->fd, s, 1);
                } else {
                        assert(n == sz);
                        silly_free(data);
                }
        } else {
                wlist_append(s, data, 0, sz);
        }
        return 0;
}

void
silly_socket_terminate()
{
        struct cmdpacket cmd;
        cmd.type = 'T';
        cmd.u.dummy[0] = 0;
        pipe_blockwrite(SSOCKET->ctrlsendfd, &cmd);
        return ;
}

//values of cmdpacket::type
//'L'   --> listen data
//'C'   --> connect
//'K'   --> close(kick)
//'S'   --> send data
//'T'   --> terminate(exit poll)

static int
cmd_process(struct silly_socket *ss)
{
        int close = 0;
        while (hascmd(ss)) {
                int err;
                struct cmdpacket cmd;
                err = pipe_blockread(ss->ctrlrecvfd, &cmd);
                if (err < 0)
                        continue;
                switch (cmd.type) {
                case 'L':
                        trylisten(ss, &cmd);
                        break;
                case 'C':
                        tryconnect(ss, &cmd);
                        break;
                case 'K':
                        if (tryclose(ss, &cmd) == 0)
                                close = 1;
                        break;
                case 'S':
                        if (trysend(ss, &cmd) < 0)
                                close = 1;
                        break;
                case 'T':       //just to return from sp_wait
                        close = -1;
                        break;
                default:
                        fprintf(stderr, "_ctrl_cmd:unkonw operation:%d\n", cmd.type);
                        assert(!"oh, no!");
                        break;
                }
        }
        return close;
}

static void
eventwait(struct silly_socket *ss)
{
        for (;;) {
                ss->eventcount = sp_wait(ss->spfd, ss->eventbuff, ss->eventcap);
                ss->eventindex = 0;
                if (ss->eventcount < 0) {
                        fprintf(stderr, "silly_socket:eventwait:%d\n", errno);
                        continue;
                }
                break;
        }
        return ;
}

int
silly_socket_poll()
{
        int err;
        sp_event_t *e;
        struct socket *s;
        struct silly_socket *ss = SSOCKET;
        eventwait(ss);
        err = cmd_process(ss);
        if (err < 0)
                return -1;
        if (err >= 1)
                clear_socket_event(ss);
        while (ss->eventindex < ss->eventcount) {
                int ei = ss->eventindex++;
                e = &ss->eventbuff[ei];
                s = (struct socket *)SP_UD(e);
                if (s == NULL)                  //the socket event has be cleared
                        continue;
                switch (s->type) {
                case STYPE_LISTEN:
                        assert(SP_READ(e));
                        report_accept(ss, s);
                        continue;
                case STYPE_CONNECTING:
                        s->type = STYPE_SOCKET;
                        report_connected(ss, s);
                        continue;
                case STYPE_RESERVE:
                        fprintf(stderr, "silly_socket_poll reserve socket\n");
                        continue;
                case STYPE_HALFCLOSE:
                case STYPE_SOCKET:
                        break;
                case STYPE_CTRL:
                        continue;
                default:
                        fprintf(stderr, "silly_socket_poll:EPOLLIN, unkonw socket type:%d\n", s->type);
                        continue;
                }

                if (SP_ERR(e)) {
                        report_close(ss, s);
                        delsocket(ss, s);
                        fprintf(stderr, "silly_socket_poll:fd:%d occurs error now\n", s->fd);
                        continue;
                }
                if (SP_READ(e)) {
                        err = forward_msg(ss, s);
                        //this socket have already occurs error, so ignore the write event
                        if (err < 0)
                                continue;
                }
                if (SP_WRITE(e)) {
                        send_msg(ss, s);
                }
        }
        return 0;
}

static void
resize_eventbuff(struct silly_socket *ss, size_t sz)
{
        ss->eventcap = sz;
        ss->eventbuff = (sp_event_t *)silly_realloc(ss->eventbuff, sizeof(sp_event_t) * sz);
        return ;
}

int
silly_socket_init()
{
        int err;
        int spfd = -1;
        int fd[2] = {-1, -1};
        struct socket *s = NULL;
        struct silly_socket *ss = silly_malloc(sizeof(*ss));
        memset(ss, 0, sizeof(*ss));
        socketpool_init(ss);
        spfd = sp_create(EVENT_SIZE);
        if (spfd < 0)
                goto end;
        s = allocsocket(ss, STYPE_CTRL);
        assert(s);
        err = pipe(fd); //use the pipe and not the socketpair because the pipe will be automatic when the data size small than BUFF_SIZE
        if (err < 0)
                goto end;
        err = sp_add(spfd, fd[0], s);
        if (err < 0)
                goto end;
        ss->spfd = spfd;
        ss->ctrlsendfd = fd[1];
        ss->ctrlrecvfd = fd[0];
        ss->eventindex = 0;
        ss->eventcount = 0;
        resize_eventbuff(ss, EVENT_SIZE);
        FD_ZERO(&ss->ctrlfdset);
        SSOCKET = ss;
        return 0;
end:
        if (s)
                freesocket(ss, s);
        if (spfd >= 0)
                close(spfd);
        if (fd[0] >= 0)
                close(fd[0]);
        if (fd[1] >= 0)
                close(fd[0]);
        if (ss)
                silly_free(ss);

        return -errno;
}

void silly_socket_exit()
{
        int i;
        assert(SSOCKET);
        close(SSOCKET->spfd);
        close(SSOCKET->ctrlsendfd);
        close(SSOCKET->ctrlrecvfd);

        struct socket *s = &SSOCKET->socketpool[0];
        for (i = 0; i < MAX_SOCKET_COUNT; i++) {
                int isnormal = 0;
                enum stype type = s->type;
                isnormal += type == STYPE_SOCKET ? 1 : 0;
                isnormal += type == STYPE_LISTEN ? 1 : 0;
                isnormal += type == STYPE_HALFCLOSE ? 1 : 0;
                if (isnormal > 0)
                        close(s->fd);
        }
        silly_free(SSOCKET->eventbuff);
        silly_free(SSOCKET->socketpool);
        silly_free(SSOCKET);
        return ;
}

