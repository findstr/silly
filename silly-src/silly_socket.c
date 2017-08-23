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
#include "atomic.h"
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

#define EVENT_SIZE (128)
#define MAX_UDP_PACKET (512)
#define MAX_SOCKET_COUNT (1 << 16)	//65536
#define MIN_READBUFF_LEN (64)

#define ARRAY_SIZE(a) (sizeof(a) / sizeof(a[0]))
#define HASH(sid) (sid % MAX_SOCKET_COUNT)

#define PROTOCOL_TCP 1
#define PROTOCOL_UDP 2
#define PROTOCOL_PIPE 3

enum stype {
	STYPE_RESERVE,
	STYPE_ALLOCED,
	STYPE_LISTEN,		//listen fd
	STYPE_UDPBIND,		//listen fd(udp)
	STYPE_SOCKET,		//socket normal status
	STYPE_HALFCLOSE,	//socket is closed
	STYPE_CONNECTING,	//socket is connecting, if success it will be STYPE_SOCKET
	STYPE_CTRL,		//pipe cmd type
};


struct wlist {
	struct wlist *next;
	size_t size;
	uint8_t *buff;
	silly_finalizer_t finalizer;
	struct sockaddr udpaddress;
};

struct socket {
	int sid;	//socket descriptor
	int fd;
	int presize;
	int protocol;
	enum stype type;
	size_t wloffset;
	struct wlist *wlhead;
	struct wlist **wltail;
};

struct silly_socket {
	sp_t spfd;
	size_t eventcap;
	//event
	int eventindex;
	int eventcount;
	sp_event_t *eventbuff;
	//socket pool
	struct socket *socketpool;
	//ctrl pipe, call write can be automatic wen data less then 64k(from APUE)
	int ctrlsendfd;
	int ctrlrecvfd;
	fd_set ctrlfdset;
	//reserve id(for socket fd remap)
	int reserveid;
	uint8_t udpbuff[MAX_UDP_PACKET];
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
		pool->wloffset = 0;
		pool->wlhead = NULL;
		pool->wltail = &pool->wlhead;
		pool++;
	}
	return ;
}

static struct socket*
allocsocket(struct silly_socket *ss, enum stype type, int protocol)
{
	int i;
	int id;
	assert(
		protocol == PROTOCOL_TCP ||
		protocol == PROTOCOL_UDP ||
		protocol == PROTOCOL_PIPE
		);
	for (i = 0; i < MAX_SOCKET_COUNT; i++) {
		id = atomic_add_return(&ss->reserveid, 1);
		if (id < 0) {
			id = id & 0x7fffffff;
			atomic_and_return(&ss->reserveid, 0x7fffffff);
		}

		struct socket *s = &ss->socketpool[HASH(id)];
		if (s->type == STYPE_RESERVE) {
			if (atomic_swap(&s->type, STYPE_RESERVE, type)) {
				assert(s->wlhead == NULL);
				assert(s->wltail == &s->wlhead);
				s->protocol = protocol;
				s->presize = MIN_READBUFF_LEN;
				s->sid = id;
				s->fd = -1;
				s->wloffset = 0;
				return s;
			}
		}
	}
	fprintf(stderr, "[socket] allocsocket fail, find no empty entry\n");
	return NULL;
}

static inline void
wlist_append(struct socket *s, uint8_t *buff, size_t size,
		silly_finalizer_t finalizer, const struct sockaddr *addr)
{
	struct wlist *w;
	w = (struct wlist *)silly_malloc(sizeof(*w));
	w->size = size;
	w->buff = buff;
	w->finalizer = finalizer;
	w->next = NULL;
	if (addr)
		w->udpaddress = *addr;
	*s->wltail = w;
	s->wltail = &w->next;
	return ;
}

static void
wlist_free(struct socket *s)
{
	struct wlist *w;
	struct wlist *t;
	w = s->wlhead;
	while (w) {
		t = w;
		w = w->next;
		assert(t->buff);
		t->finalizer(t->buff);
		silly_free(t);
	}
	s->wlhead = NULL;
	s->wltail = &s->wlhead;
	return ;
}
static inline int
wlist_empty(struct socket *s)
{
	return s->wlhead == NULL ? 1 : 0;
}

static inline void
freesocket(struct silly_socket *ss, struct socket *s)
{
	(void)ss;
	wlist_free(s);
	assert(s->wlhead == NULL);
	atomic_barrier();
	s->type = STYPE_RESERVE;
}

static struct socket *
newsocket(struct silly_socket *ss, struct socket *s, int fd, enum stype type, void (* report)(struct silly_socket *ss, struct socket *s, int err))
{
	int err;
	if (s == NULL)
		s = allocsocket(ss, type, PROTOCOL_TCP);
	if (s == NULL) {
		close(fd);
		return NULL;
	}
	assert(s->type == type || s->type == STYPE_ALLOCED);
	assert(s->presize == MIN_READBUFF_LEN);
	assert(fd >= 0);
	s->fd = fd;
	s->type = type;
	err = sp_add(ss->spfd, fd, s);
	if (err < 0) {
		if (report)
			report(ss, s, errno);
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
		const char *fmt = "[socket] delsocket sid:%d error type:%d\n";
		fprintf(stderr, fmt, s->sid, s->type);
		return ;
	}
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
	s = newsocket(ss, NULL, fd, STYPE_SOCKET, NULL);
	if (s == NULL)
		return;
	sa->sid = s->sid;
	sa->ud = listen->sid;
	silly_worker_push(tocommon(sa));
	return ;
}

static void
report_close(struct silly_socket *ss, struct socket *s, int err)
{
	(void)ss;
	int type;
	struct silly_message_socket *sc;
	if (s->type == STYPE_HALFCLOSE)//don't notify the active close
		return ;
	type = s->type;
	assert(type == STYPE_LISTEN ||
		type == STYPE_SOCKET ||
		type == STYPE_CONNECTING ||
		type == STYPE_ALLOCED);
	sc = silly_malloc(sizeof(*sc));
	sc->type = SILLY_SCLOSE;
	sc->sid = s->sid;
	sc->ud = err;
	silly_worker_push(tocommon(sc));
	return ;
}

static void
report_data(struct silly_socket *ss, struct socket *s, int type, uint8_t *data, size_t sz)
{
	(void)ss;
	assert(s->type == STYPE_SOCKET || s->type == STYPE_UDPBIND);
	struct silly_message_socket *sd = silly_malloc(sizeof(*sd));
	assert(type == SILLY_SDATA || type == SILLY_SUDP);
	sd->type = type;
	sd->sid = s->sid;
	sd->ud = sz;
	sd->data = data;
	silly_worker_push(tocommon(sd));
	return ;
};

static inline int
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
		fprintf(stderr, "[socket] checkconnected:%d\n", err);
		return -1;
	}
	return 0;
}

static void
report_connected(struct silly_socket *ss, struct socket *s)
{
	int err;
	err = checkconnected(s->fd);
	if (err < 0) {	//check ok
		report_close(ss, s, errno);
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
				continue;
			case ETRYAGAIN:
				return 0;
			default:
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
				continue;
			case ETRYAGAIN:
				return 0;
			default:
				return -1;
			}
		}
		return len;
	}
	assert(!"never come here");
	return 0;
}

static ssize_t
readudp(int fd, uint8_t *buff, size_t sz, struct sockaddr *addr, socklen_t *addrlen)
{
	ssize_t n;
	for (;;) {
		n = recvfrom(fd, buff, sz, 0, addr, addrlen);
		if (n >= 0) {
			assert(sizeof(struct sockaddr) <= (*addrlen));
			return n;
		}
		switch (errno) {
		case EINTR:
			continue;
		case ETRYAGAIN:
			return -1;
		default:
			return -1;
		}
	}
	return 0;
}

static ssize_t
sendudp(int fd, uint8_t *data, size_t sz, const struct sockaddr *addr)
{
	ssize_t n;
	for (;;) {
		n = sendto(fd, data, sz, 0, addr, sizeof(*addr));
		if (n >= 0)
			return n;
		switch (errno) {
		case EINTR:
			continue;
		case ETRYAGAIN:
			return -2;
		default:
			return -1;
		}
	}
	return 0;
}



static int
forward_msg_tcp(struct silly_socket *ss, struct socket *s)
{
	ssize_t sz;
	ssize_t presize = s->presize;
	uint8_t *buff = (uint8_t *)silly_malloc(presize);
	sz = readn(s->fd, buff, presize);
	//half close socket need no data
	if (sz > 0 && s->type != STYPE_HALFCLOSE) {
		report_data(ss, s, SILLY_SDATA, buff, sz);
		//to predict the pakcet size
		if (sz == presize) {
			s->presize *= 2;
		} else if (presize > MIN_READBUFF_LEN) {
			//s->presize at leatest is 2 * MIN_READBUFF_LEN
			int half = presize / 2;
			if (sz < half)
				s->presize = half;
		}
	} else {
		silly_free(buff);
		if (sz < 0) {
			report_close(ss, s, errno);
			delsocket(ss, s);
			return -1;
		}
		return 0;
	}
	return sz;
}

static int
forward_msg_udp(struct silly_socket *ss, struct socket *s)
{
	ssize_t n;
	uint8_t *data;
	struct sockaddr addr;
	socklen_t len = sizeof(addr);
	n = readudp(s->fd, ss->udpbuff, MAX_UDP_PACKET, &addr, &len);
	if (n < 0)
		return 0;
	data = (uint8_t *)silly_malloc(n + sizeof(addr));
	memcpy(data, ss->udpbuff, n);
	memcpy(data + n, &addr, sizeof(addr));
	report_data(ss, s, SILLY_SUDP, data, n);
	return n;
}

const char *
silly_socket_udpaddress(const char *data, size_t *addrlen)
{
	*addrlen = sizeof(struct sockaddr);
	return data;
}

static void
send_msg_tcp(struct silly_socket *ss, struct socket *s)
{
	struct wlist *w;
	w = s->wlhead;
	assert(w);
	while (w) {
		ssize_t sz;
		assert(w->size > s->wloffset);
		sz = sendn(s->fd, w->buff + s->wloffset, w->size - s->wloffset);
		if (sz < 0) {
			report_close(ss, s, errno);
			delsocket(ss, s);
			return ;
		}
		s->wloffset += sz;
		if (s->wloffset < w->size) //send some
			return ;
		assert((size_t)s->wloffset == w->size);
		s->wloffset = 0;
		s->wlhead = w->next;
		w->finalizer(w->buff);
		silly_free(w);
		w = s->wlhead;
		if (w == NULL) {//send ok
			s->wltail = &s->wlhead;
			sp_write_enable(ss->spfd, s->fd, s, 0);
			if (s->type == STYPE_HALFCLOSE)
				delsocket(ss, s);
		}
	}
	return ;
}

static void
send_msg_udp(struct silly_socket *ss, struct socket *s)
{
	struct wlist *w;
	w = s->wlhead;
	assert(w);
	while (w) {
		ssize_t sz;
		sz = sendudp(s->fd, w->buff, w->size, &w->udpaddress);
		if (sz == -2)	//EAGAIN, so block it
			break;
		assert(sz == -1 || (size_t)sz == w->size);
		//send fail && send ok will clear
		s->wlhead = w->next;
		w->finalizer(w->buff);
		silly_free(w);
		w = s->wlhead;
		if (w == NULL) {//send all
			s->wltail = &s->wlhead;
			sp_write_enable(ss->spfd, s->fd, s, 0);
			if (s->type == STYPE_HALFCLOSE)
				delsocket(ss, s);
		}
	}
	return ;
}

static inline int
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
	int type;
	union {
		char dummy[128];
		struct {
			int sid;
		} listen; //'L' 'B'
		struct {
			char ip[64];
			int  port;
			char bip[64];
			int  bport;
			int  sid;
		} connect; //'C'
		struct {
			int sid;
			int fd;
		} udpconnect; //'O'
		struct {
			int sid;
		} close;   //'K'
		struct {
			int sid;
			ssize_t size;
			uint8_t *data;
			silly_finalizer_t finalizer;
		} send; //'S'
		struct {
			int sid;
			ssize_t size;
			uint8_t *data;
			struct sockaddr to;
			silly_finalizer_t finalizer;
		} udpsend;  //'U'
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

static inline void
tosockaddr(struct sockaddr *addr, const char *ip, int port)
{
	struct sockaddr_in *in = (struct sockaddr_in *)addr;
	bzero(addr, sizeof(*addr));
	in->sin_family = AF_INET;
	in->sin_port = htons(port);
	inet_pton(AF_INET, ip, &in->sin_addr);
}


static int
bindfd(int fd, const char *ip, int port)
{
	int err;
	struct sockaddr addr;
	if (ip[0] == '\0' && port == 0)
		return 0;
	tosockaddr(&addr, ip, port);
	err = bind(fd, &addr, sizeof(addr));
	return err;
}

static int
dolisten(const char *ip, uint16_t port, int backlog)
{
	int err;
	int fd;
	int reuse = 1;
	fd = socket(AF_INET, SOCK_STREAM, 0);
	if (fd < 0)
		return -1;
	setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
	err = bindfd(fd, ip, port);
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
	s = allocsocket(SSOCKET, STYPE_ALLOCED, PROTOCOL_TCP);
	if (s == NULL) {
		fprintf(stderr, "[socket] listen %s:%d:%d allocsocket fail\n", ip, port, backlog);
		close(fd);
		return -1;
	}

	s->fd = fd;
	cmd.type = 'L';
	cmd.u.listen.sid = s->sid;
	pipe_blockwrite(SSOCKET->ctrlsendfd, &cmd);
	return s->sid;
}

int
silly_socket_udpbind(const char *ip, uint16_t port)
{
	int fd;
	int err;
	struct socket *s;
	struct cmdpacket cmd;
	fd = socket(AF_INET, SOCK_DGRAM, 0);
	if (fd < 0)
		return -1;
	err = bindfd(fd, ip, port);
	if (err < 0)
		goto end;
	nonblock(fd);
	s = allocsocket(SSOCKET, STYPE_ALLOCED, PROTOCOL_UDP);
	if (s == NULL) {
		fprintf(stderr, "[socket] udplisten %s:%d allocsocket fail\n", ip, port);
		goto end;
	}
	s->fd = fd;
	cmd.type = 'B';
	cmd.u.listen.sid = s->sid;
	pipe_blockwrite(SSOCKET->ctrlsendfd, &cmd);
	return s->sid;
end:
	perror("udplisten");
	close(fd);
	return -1;
}

static int
trylisten(struct silly_socket *ss, struct cmdpacket *cmd)
{
	int err;
	int sid = cmd->u.listen.sid;
	struct socket *s = &ss->socketpool[HASH(sid)];
	assert(s->sid == sid);
	assert(s->type == STYPE_ALLOCED);
	err = sp_add(ss->spfd, s->fd, s);
	if (err < 0) {
		perror("trylisten");
		report_close(ss, s, errno);
		close(s->fd);
		freesocket(ss, s);
		return err;
	}
	s->type = STYPE_LISTEN;
	return err;
}

static int
tryudpbind(struct silly_socket *ss, struct cmdpacket *cmd)
{
	int err;
	int sid = cmd->u.listen.sid;
	struct socket *s = &ss->socketpool[HASH(sid)];
	assert(s->sid == sid);
	assert(s->type = STYPE_ALLOCED);
	err = sp_add(ss->spfd, s->fd, s);
	if (err < 0) {
		perror("tryudpbind");
		report_close(ss, s, errno);
		close(s->fd);
		freesocket(ss, s);
		return err;
	}
	assert(s->protocol == PROTOCOL_UDP);
	s->type = STYPE_UDPBIND;
	assert(err == 0);
	return err;
}

static inline void
fill_connectaddr(struct cmdpacket *cmd, const char *addr, int port, const char *bindip, int bindport)
{
	size_t sz;
	sz = ARRAY_SIZE(cmd->u.connect.ip) - 1;
	strncpy(cmd->u.connect.ip, addr, sz);
	cmd->u.connect.ip[sz] = '\0';
	sz = ARRAY_SIZE(cmd->u.connect.bip) - 1;
	strncpy(cmd->u.connect.bip, bindip, sz);
	cmd->u.connect.bip[sz] = '\0';
	cmd->u.connect.port = port;
	cmd->u.connect.bport = bindport;
	return ;
}

int
silly_socket_connect(const char *addr, int port, const char *bindip, int bindport)
{
	struct cmdpacket cmd;
	struct socket *s;
	s = allocsocket(SSOCKET, STYPE_ALLOCED, PROTOCOL_TCP);
	if (s == NULL)
		return -1;
	assert(addr);
	assert(bindip);
	cmd.type = 'C';
	cmd.u.connect.sid = s->sid;
	fill_connectaddr(&cmd, addr, port, bindip, bindport);
	pipe_blockwrite(SSOCKET->ctrlsendfd, &cmd);
	return s->sid;
}

static void
tryconnect(struct silly_socket *ss, struct cmdpacket *cmd)
{
	int err;
	int fd;
	struct sockaddr addr;
	int sid = cmd->u.connect.sid;
	int port = cmd->u.connect.port;
	int bport = cmd->u.connect.bport;
	const char *ip = cmd->u.connect.ip;
	const char *bip = cmd->u.connect.bip;
	struct socket *s =  &ss->socketpool[HASH(sid)];
	assert(s->sid == sid);
	assert(s->type == STYPE_ALLOCED);
	tosockaddr(&addr, ip, port);
	fd = socket(AF_INET, SOCK_STREAM, 0);
	if (fd >= 0)
		err = bindfd(fd, bip, bport);
	if (fd < 0 || err < 0) {
		const char *fmt = "[socket] bind %s:%d, errno:%d\n";
		fprintf(stderr, fmt, bip, bport, errno);
		if (fd >= 0)
			close(fd);
		report_close(ss, s, errno);
		freesocket(ss, s);
		return ;
	}
	nonblock(fd);
	keepalive(fd);
	nodelay(fd);
	err = connect(fd, &addr, sizeof(addr));
	if (err == -1 && errno != EINPROGRESS) {	//error
		const char *fmt = "[socket] tryconnect %s:%d,errno:%d\n";
		fprintf(stderr, fmt, ip, port, errno);
		close(fd);
		report_close(ss, s, errno);
		freesocket(ss, s);
		return ;
	} else if (err == 0) {	//connect
		s = newsocket(ss, s, fd, STYPE_SOCKET, report_close);
		if (s != NULL)
			report_connected(ss, s);
		return ;
	} else {	//block
		s = newsocket(ss, s, fd, STYPE_CONNECTING, report_close);
		if (s != NULL)
			sp_write_enable(ss->spfd, s->fd, s, 1);
	}
	return ;
}

int
silly_socket_udpconnect(const char *addr, int port, const char *bindip, int bindport)
{
	int fd;
	int err;
	struct socket *s = NULL;
	struct sockaddr addr_connect;
	struct cmdpacket cmd;
	const char *fmt = "[socket] udpconnect %s:%d, errno:%d\n";
	fd = socket(AF_INET, SOCK_DGRAM, 0);
	if (fd < 0)
		goto end;
	s = allocsocket(SSOCKET, STYPE_ALLOCED, PROTOCOL_UDP);
	if (s == NULL)
		goto end;
	assert(addr);
	assert(bindip);
	tosockaddr(&addr_connect, addr, port);
	err = bindfd(fd, bindip, bindport);
	if (err < 0)
		goto end;
	//udp connect will return immediately
	err = connect(fd, &addr_connect, sizeof(addr_connect));
	if (err < 0)
		goto end;
	cmd.type = 'O';
	cmd.u.udpconnect.sid = s->sid;
	cmd.u.udpconnect.fd = fd;
	pipe_blockwrite(SSOCKET->ctrlsendfd, &cmd);
	return s->sid;
end:
	if (fd >= 0)
		close(fd);
	if (s)
		freesocket(SSOCKET, s);
	fprintf(stderr, fmt, addr, port, errno);
	return -1;
}

static void
tryudpconnect(struct silly_socket *ss, struct cmdpacket *cmd)
{
	int sid = cmd->u.udpconnect.sid;
	struct socket *s =  &ss->socketpool[HASH(sid)];
	assert(s->sid == sid);
	assert(s->type == STYPE_ALLOCED);
	s = newsocket(ss, s, cmd->u.udpconnect.fd, STYPE_SOCKET, report_close);
	if (s != NULL)
		report_connected(ss, s);
	return ;
}


static inline struct socket *
checksocket(struct silly_socket *ss, int sid)
{
	struct socket *s = &ss->socketpool[HASH(sid)];
	if (s->sid != sid) {
		fprintf(stderr, "[socket] checksocket invalid sid\n");
		return NULL;
	}
	switch (s->type) {
	case STYPE_LISTEN:
	case STYPE_SOCKET:
	case STYPE_UDPBIND:
		return s;
	default:
		fprintf(stderr,
			"[socket] checksocket sid:%d unsupport type:%d\n",
			s->sid, s->type);
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
silly_socket_send(int sid, uint8_t *buff, size_t sz, silly_finalizer_t finalizer)
{
	struct cmdpacket cmd;
	struct socket *s = checksocket(SSOCKET, sid);
	finalizer = finalizer ? finalizer : silly_free;
	if (s == NULL) {
		finalizer(buff);
		return -1;
	}
	if (sz == 0) {
		finalizer(buff);
		return -1;
	}
	cmd.type = 'S';
	cmd.u.send.sid = sid;
	cmd.u.send.data = buff;
	cmd.u.send.size = sz;
	cmd.u.send.finalizer = finalizer;
	pipe_blockwrite(SSOCKET->ctrlsendfd, &cmd);
	return 0;
}

int
silly_socket_udpsend(int sid, uint8_t *buff, size_t sz, const char *addr, size_t addrlen, silly_finalizer_t finalizer)
{
	struct cmdpacket cmd;
	struct socket *s = checksocket(SSOCKET, sid);
	finalizer = finalizer ? finalizer : silly_free;
	if (s == NULL) {
		finalizer(buff);
		return -1;
	}
	assert(s->protocol = PROTOCOL_UDP);
	assert(s->type == STYPE_UDPBIND || s->type == STYPE_SOCKET);
	if (s->type == STYPE_UDPBIND && addr == NULL) {
		finalizer(buff);
		fprintf(stderr, "[socket] udpsend udpbind socket must specify dest addr\n");
		return -1;
	}
	cmd.type = 'U';
	cmd.u.udpsend.sid = sid;
	cmd.u.udpsend.data= buff;
	cmd.u.udpsend.size = sz;
	cmd.u.udpsend.finalizer = finalizer;
	if (s->type == STYPE_UDPBIND) {//udp bind socket need sendto address
		assert(addrlen == sizeof(cmd.u.udpsend.to));
		memcpy(&cmd.u.udpsend.to, addr, sizeof(cmd.u.udpsend.to));
	}
	pipe_blockwrite(SSOCKET->ctrlsendfd, &cmd);
	return 0;
}


static int
trysend(struct silly_socket *ss, struct cmdpacket *cmd)
{
	struct socket *s = checksocket(ss, cmd->u.send.sid);
	uint8_t *data = cmd->u.send.data;
	size_t sz = cmd->u.send.size;
	silly_finalizer_t finalizer = cmd->u.send.finalizer;
	if (s == NULL) {
		finalizer(data);
		return 0;
	}
	if (wlist_empty(s)) {//try send
		ssize_t n = sendn(s->fd, data, sz);
		if (n < 0) {
			finalizer(data);
			report_close(ss, s, errno);
			delsocket(ss, s);
			return -1;
		} else if ((size_t)n < sz) {
			s->wloffset = n;
			wlist_append(s, data, sz, finalizer, NULL);
			sp_write_enable(ss->spfd, s->fd, s, 1);
		} else {
			assert((size_t)n == sz);
			finalizer(data);
		}
	} else {
		wlist_append(s, data, sz, finalizer, NULL);
	}
	return 0;
}

static int
tryudpsend(struct silly_socket *ss, struct cmdpacket *cmd)
{
	struct socket *s = checksocket(ss, cmd->u.udpsend.sid);
	uint8_t *data = cmd->u.udpsend.data;
	size_t sz = cmd->u.udpsend.size;
	const struct sockaddr *addr = &cmd->u.udpsend.to;
	silly_finalizer_t finalizer = cmd->u.udpsend.finalizer;
	if (s == NULL) {
		finalizer(data);
		return 0;
	}
	assert(s->protocol == PROTOCOL_UDP);
	if (s->type == STYPE_SOCKET) //udp client need no address
		addr = NULL;
	if (wlist_empty(s)) {//try send
		ssize_t n = sendudp(s->fd, data, sz, addr);
		if (n == -1 || n >= 0) {	//occurs error or send ok
			finalizer(data);
			return 0;
		}
		assert(n == -2);	//EAGAIN
		wlist_append(s, data, sz, finalizer, addr);
	} else {
		wlist_append(s, data, sz, finalizer, addr);
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
//'L'	--> listen(tcp)
//'B'	--> bind(udp)
//'C'	--> connect(tcp)
//'O'	--> connect(udp)
//'K'	--> close(kick)
//'S'	--> send data(tcp)
//'U'	--> send data(udp)
//'T'	--> terminate(exit poll)

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
		case 'B':
			tryudpbind(ss, &cmd);
			break;
		case 'C':
			tryconnect(ss, &cmd);
			break;
		case 'O':
			tryudpconnect(ss, &cmd);
			break;
		case 'K':
			if (tryclose(ss, &cmd) == 0)
				close = 1;
			break;
		case 'S':
			if (trysend(ss, &cmd) < 0)
				close = 1;
			break;
		case 'U':
			tryudpsend(ss, &cmd);	//udp socket can only be closed active
			break;
		case 'T':	//just to return from sp_wait
			close = -1;
			break;
		default:
			fprintf(stderr, "[socket] cmd_process:unkonw operation:%d\n", cmd.type);
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
			fprintf(stderr, "[socket] eventwait:%d\n", errno);
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
		if (s == NULL)			//the socket event has be cleared
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
			fprintf(stderr, "[socket] poll reserve socket\n");
			continue;
		case STYPE_HALFCLOSE:
		case STYPE_SOCKET:
		case STYPE_UDPBIND:
			break;
		case STYPE_CTRL:
			continue;
		default:
			fprintf(stderr, "[socket] poll: unkonw socket type:%d\n", s->type);
			continue;
		}

		if (SP_ERR(e)) {
			report_close(ss, s, 0);
			delsocket(ss, s);
			continue;
		}
		if (SP_READ(e)) {
			switch (s->protocol) {
			case PROTOCOL_TCP:
				err = forward_msg_tcp(ss, s);
				break;
			case PROTOCOL_UDP:
				err = forward_msg_udp(ss, s);
				break;
			default:
				fprintf(stderr, "[socket] poll: unsupport protocol:%d\n", s->protocol);
				continue;
			}
			//this socket have already occurs error, so ignore the write event
			if (err < 0)
				continue;
		}
		if (SP_WRITE(e)) {
			if (s->protocol == PROTOCOL_TCP)
				send_msg_tcp(ss, s);
			else
				send_msg_udp(ss, s);
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
	sp_t spfd = SP_INVALID;
	int fd[2] = {-1, -1};
	struct socket *s = NULL;
	struct silly_socket *ss = silly_malloc(sizeof(*ss));
	memset(ss, 0, sizeof(*ss));
	socketpool_init(ss);
	spfd = sp_create(EVENT_SIZE);
	if (spfd == SP_INVALID)
		goto end;
	s = allocsocket(ss, STYPE_CTRL, PROTOCOL_PIPE);
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
	if (spfd != SP_INVALID)
		sp_free(spfd);
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
	sp_free(SSOCKET->spfd);
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

