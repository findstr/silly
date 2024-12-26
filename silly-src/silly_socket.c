#include "silly_conf.h"
#include <assert.h>
#include <stdio.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>

#include "silly.h"
#include "atomic.h"
#include "compiler.h"
#include "net.h"
#include "silly_log.h"
#include "pipe.h"
#include "event.h"
#include "nonblock.h"
#include "silly_worker.h"
#include "silly_malloc.h"
#include "silly_socket.h"

//STYPE == socket type

#if EAGAIN == EWOULDBLOCK
#define ETRYAGAIN EAGAIN
#else
#define ETRYAGAIN \
EAGAIN:           \
	case EWOULDBLOCK
#endif

#ifdef __WIN32
#define CONNECT_IN_PROGRESS EWOULDBLOCK
#undef errno
#define errno translate_socket_errno(WSAGetLastError())
#else
#define CONNECT_IN_PROGRESS EINPROGRESS
#define closesocket close
#endif

#define EVENT_SIZE (128)
#define CMDBUF_SIZE (8 * sizeof(struct cmdpacket))
#define MAX_UDP_PACKET (512)
#define MAX_SOCKET_COUNT (1 << SOCKET_MAX_EXP)
#define MIN_READBUF_LEN (64)

#define ARRAY_SIZE(a) (sizeof(a) / sizeof(a[0]))
#define HASH(sid) (sid & (MAX_SOCKET_COUNT - 1))

#define PROTOCOL_TCP 1
#define PROTOCOL_UDP 2
#define PROTOCOL_PIPE 3

enum stype {
	STYPE_RESERVE,
	STYPE_ALLOCED,
	STYPE_LISTEN,   //listen fd
	STYPE_UDPBIND,  //listen fd(udp)
	STYPE_SOCKET,   //socket normal status
	STYPE_SHUTDOWN, //socket is closed
	STYPE_CONNECTING, //socket is connecting, if success it will be STYPE_SOCKET
	STYPE_CTRL,       //pipe cmd type
};

static const char *protocol_name[] = {
	"INVALID",
	"TCP",
	"UDP",
	"PIPE",
};

static const char *stype_name[] = {
	"RESERVE", "ALLOCED",  "LISTEN",     "UDPBIND",
	"SOCKET",  "SHUTDOWN", "CONNECTING", "CTRL",
};

//replace 'sockaddr_storage' with this struct,
//because we only care about 'ipv6' and 'ipv4'
#define SA_LEN(sa)                                                \
	((sa).sa_family == AF_INET ? sizeof(struct sockaddr_in) : \
				     sizeof(struct sockaddr_in6))

union sockaddr_full {
	struct sockaddr sa;
	struct sockaddr_in v4;
	struct sockaddr_in6 v6;
};

struct wlist {
	struct wlist *next;
	size_t size;
	uint8_t *buf;
	silly_finalizer_t finalizer;
	union sockaddr_full *udpaddress;
};

struct socket {
	int sid; //socket descriptor
	fd_t fd;
	unsigned char protocol;
	unsigned char reading;
	int presize;
	enum stype type;
	size_t wloffset;
	struct wlist *wlhead;
	struct wlist **wltail;
};

struct silly_socket {
	fd_t spfd;
	//reverse for accept
	//when reach the limit of file descriptor's number
	int reservefd;
	//event
	int eventindex;
	int eventcount;
	size_t eventcap;
	event_t *eventbuf;
	//socket pool
	struct socket *socketpool;
	//ctrl pipe, call write can be automatic
	//when data less then 64k(from APUE)
	int ctrlsendfd;
	int ctrlrecvfd;
	int ctrlcount;
	int cmdcap;
	uint8_t *cmdbuf;
	//reserve id(for socket fd remap)
	int reserveid;
	//netstat
	struct silly_netstat netstat;
	//error message
	char errmsg[256];
};

//for read one complete packet once system call, fix the packet length
#define cmdcommon int type
struct cmdlisten { //'L/B' -> listen or bind
	cmdcommon;
	int sid;
};

struct cmdconnect { //'C' -> tcp connect
	cmdcommon;
	int sid;
	union sockaddr_full addr;
};

struct cmdopen { //'O' -> udp connect
	cmdcommon;
	int sid;
};

struct cmdkick { //'K' --> close
	cmdcommon;
	int sid;
};

struct cmdsend { //'S' --> tcp send
	cmdcommon;
	int sid;
	int size;
	uint8_t *data;
	silly_finalizer_t finalizer;
};

struct cmdudpsend { //'U' --> udp send
	struct cmdsend send;
	union sockaddr_full addr;
};

struct cmdreadctrl { //'R' --> read ctrl
	cmdcommon;
	int sid;
	int ctrl;
};

struct cmdterm {
	cmdcommon;
};

struct cmdpacket {
	union {
		cmdcommon;
		struct cmdlisten listen;
		struct cmdconnect connect;
		struct cmdopen open;
		struct cmdkick kick;
		struct cmdsend send;
		struct cmdudpsend udpsend;
		struct cmdreadctrl readctrl;
		struct cmdterm term;
	} u;
};

static struct silly_socket *SSOCKET;

static inline void reset_errmsg(struct silly_socket *ss)
{
	ss->errmsg[0] = '\0';
}

static inline void set_errmsg(struct silly_socket *ss, const char *str)
{
	snprintf(ss->errmsg, sizeof(ss->errmsg), "%s", str);
}

static void socketpool_init(struct silly_socket *ss)
{
	int i;
	struct socket *pool = silly_malloc(sizeof(*pool) * MAX_SOCKET_COUNT);
	ss->socketpool = pool;
	ss->reserveid = -1;
	for (i = 0; i < MAX_SOCKET_COUNT; i++) {
		pool->sid = -1;
		pool->fd = -1;
		pool->type = STYPE_RESERVE;
		pool->presize = MIN_READBUF_LEN;
		pool->wloffset = 0;
		pool->wlhead = NULL;
		pool->wltail = &pool->wlhead;
		pool++;
	}
	return;
}

static inline void wlist_append(struct socket *s, uint8_t *buf, size_t size,
				silly_finalizer_t finalizer)
{
	struct wlist *w;
	w = (struct wlist *)silly_malloc(sizeof(*w));
	w->size = size;
	w->buf = buf;
	w->finalizer = finalizer;
	w->next = NULL;
	w->udpaddress = NULL;
	*s->wltail = w;
	s->wltail = &w->next;
	return;
}

static inline void wlist_appendudp(struct socket *s, uint8_t *buf, size_t size,
				   silly_finalizer_t finalizer,
				   const union sockaddr_full *addr)
{
	int addrsz;
	struct wlist *w;
	addrsz = addr ? SA_LEN(addr->sa) : 0;
	w = (struct wlist *)silly_malloc(sizeof(*w) + addrsz);
	w->size = size;
	w->buf = buf;
	w->finalizer = finalizer;
	w->next = NULL;
	if (addrsz != 0) {
		w->udpaddress = (union sockaddr_full *)(w + 1);
		memcpy(w->udpaddress, addr, addrsz);
	} else {
		w->udpaddress = NULL;
	}
	*s->wltail = w;
	s->wltail = &w->next;
	return;
}

static void wlist_free(struct socket *s)
{
	struct wlist *w;
	struct wlist *t;
	w = s->wlhead;
	while (w) {
		t = w;
		w = w->next;
		assert(t->buf);
		t->finalizer(t->buf);
		silly_free(t);
	}
	s->wlhead = NULL;
	s->wltail = &s->wlhead;
	return;
}
static inline int wlist_empty(struct socket *s)
{
	return s->wlhead == NULL ? 1 : 0;
}

static struct socket *allocsocket(struct silly_socket *ss, fd_t fd,
				  enum stype type, unsigned char protocol)
{
	int i;
	int id;
	assert(protocol == PROTOCOL_TCP || protocol == PROTOCOL_UDP ||
	       protocol == PROTOCOL_PIPE);
	for (i = 0; i < MAX_SOCKET_COUNT; i++) {
		id = atomic_add_return(&ss->reserveid, 1);
		if (unlikely(id < 0)) {
			id = id & 0x7fffffff;
			atomic_and_return(&ss->reserveid, 0x7fffffff);
		}
		struct socket *s = &ss->socketpool[HASH(id)];
		if (s->type != STYPE_RESERVE) {
			continue;
		}
		if (atomic_swap(&s->type, STYPE_RESERVE, type)) {
			assert(s->wlhead == NULL);
			assert(s->wltail == &s->wlhead);
			s->protocol = protocol;
			s->presize = MIN_READBUF_LEN;
			s->sid = id;
			s->fd = fd;
			s->wloffset = 0;
			s->reading = 1;
			return s;
		}
	}
	set_errmsg(ss, "socket pool is full");
	silly_log_error("[socket] allocsocket fail, find no empty entry\n");
	return NULL;
}

static inline void netstat_close(struct silly_socket *ss, struct socket *s)
{
	if (s->protocol != PROTOCOL_TCP) {
		return;
	}
	ss->netstat.tcpclient--;
}

static inline void freesocket(struct silly_socket *ss, struct socket *s)
{
	if (unlikely(s->type == STYPE_RESERVE)) {
		const char *fmt = "[socket] freesocket sid:%d error type:%d\n";
		silly_log_error(fmt, s->sid, s->type);
		return;
	}
	if (s->fd >= 0) {
		sp_del(ss->spfd, s->fd);
		closesocket(s->fd);
		s->fd = -1;
	}
	wlist_free(s);
	assert(s->wlhead == NULL);
	netstat_close(ss, s);
	atomic_barrier();
	s->type = STYPE_RESERVE;
}

static void clear_socket_event(struct silly_socket *ss)
{
	int i;
	struct socket *s;
	event_t *e;
	for (i = ss->eventindex; i < ss->eventcount; i++) {
		e = &ss->eventbuf[i];
		s = SP_UD(e);
		if (s == NULL)
			continue;
		if (unlikely(s->type == STYPE_RESERVE))
			SP_UD(e) = NULL;
	}
	return;
}

static void nodelay(fd_t fd)
{
	int err;
	int on = 1;
	err = setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, (void *)&on, sizeof(on));
	if (err >= 0)
		return;
	silly_log_error("[socket] nodelay error:%s\n", strerror(errno));
	return;
}

static void keepalive(fd_t fd)
{
	int err;
	int on = 1;
	err = setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, (void *)&on, sizeof(on));
	if (err >= 0)
		return;
	silly_log_error("[socket] keepalive error:%s\n", strerror(errno));
}

static int ntop(union sockaddr_full *addr, char namebuf[SOCKET_NAMELEN])
{
	uint16_t port;
	int namelen, family;
	char *buf = namebuf;
	family = addr->sa.sa_family;
	if (family == AF_INET) {
		port = addr->v4.sin_port;
		inet_ntop(family, &addr->v4.sin_addr, buf, INET_ADDRSTRLEN);
		namelen = strlen(buf);
	} else {
		assert(family == AF_INET6);
		port = addr->v6.sin6_port;
		inet_ntop(family, &addr->v6.sin6_addr, buf, INET6_ADDRSTRLEN);
		namelen = strlen(buf);
	}
	port = ntohs(port);
	namelen +=
		snprintf(&buf[namelen], SOCKET_NAMELEN - namelen, ":%d", port);
	return namelen;
}

static void pipe_blockread(fd_t fd, void *pk, int n)
{
	for (;;) {
		ssize_t err = pipe_read(fd, pk, n);
		if (err == -1) {
			if (likely(errno == EINTR))
				continue;
			silly_log_error("[socket] pip_blockread error:%s\n",
					strerror(errno));
			return;
		}
		assert(err == n);
		atomic_sub_return(&SSOCKET->ctrlcount, n);
		return;
	}
}

static int pipe_blockwrite(fd_t fd, void *pk, int sz)
{
	for (;;) {
		ssize_t err = pipe_write(fd, pk, sz);
		if (err == -1) {
			if (likely(errno == EINTR))
				continue;
			silly_log_error("[socket] pipe_blockwrite error:%s",
					strerror(errno));
			return -1;
		}
		atomic_add(&SSOCKET->ctrlcount, sz);
		assert(err == sz);
		return 0;
	}
}

static void report_accept(struct silly_socket *ss, struct socket *listen)
{
	int err, fd;
	struct socket *s;
	union sockaddr_full addr;
	struct silly_message_socket *sa;
	socklen_t len = sizeof(addr);
	char namebuf[SOCKET_NAMELEN];
#ifndef USE_ACCEPT4
	fd = accept(listen->fd, &addr.sa, &len);
#else
	fd = accept4(listen->fd, &addr.sa, &len, SOCK_NONBLOCK);
#endif
	if (unlikely(fd < 0)) {
		if (errno != EMFILE && errno != ENFILE)
			return;
		closesocket(ss->reservefd);
		fd = accept(listen->fd, NULL, NULL);
		closesocket(fd);
		silly_log_error(
			"[socket] accept reach limit of file descriptor\n");
		ss->reservefd = open("/dev/null", O_RDONLY);
		return;
	}
#ifndef USE_ACCEPT4
	nonblock(fd);
#endif
	keepalive(fd);
	nodelay(fd);
	s = allocsocket(ss, fd, STYPE_SOCKET, PROTOCOL_TCP);
	if (unlikely(s == NULL)) {
		closesocket(fd);
		return;
	}
	err = sp_add(ss->spfd, fd, s);
	if (err < 0) {
		freesocket(ss, s);
		return;
	}
	int namelen = ntop(&addr, namebuf);
	sa = silly_malloc(sizeof(*sa) + namelen + 1);
	sa->type = SILLY_SACCEPT;
	sa->sid = s->sid;
	sa->ud = listen->sid;
	sa->data = (uint8_t *)(sa + 1);
	*sa->data = namelen;
	memcpy(sa->data + 1, namebuf, namelen);
	silly_worker_push(tocommon(sa));
	ss->netstat.tcpclient++;
	return;
}

static void report_close(struct silly_socket *ss, struct socket *s, int err)
{
	(void)ss;
	int type;
	struct silly_message_socket *sc;
	if (s->type == STYPE_SHUTDOWN) //don't notify the active close
		return;
	type = s->type;
	assert(type == STYPE_LISTEN || type == STYPE_SOCKET ||
	       type == STYPE_CONNECTING || type == STYPE_ALLOCED);
	sc = silly_malloc(sizeof(*sc));
	sc->type = SILLY_SCLOSE;
	sc->sid = s->sid;
	sc->ud = err;
	silly_worker_push(tocommon(sc));
	return;
}

static void report_data(struct silly_socket *ss, struct socket *s, int type,
			uint8_t *data, size_t sz)
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
	return;
};

static void write_enable(struct silly_socket *ss, struct socket *s, int enable)
{
	int flag;
	if (likely(s->reading != 0))
		flag = SP_IN;
	else
		flag = 0;
	if (enable != 0)
		flag |= SP_OUT;
	sp_ctrl(ss->spfd, s->fd, s, flag);
}

static void read_enable(struct silly_socket *ss, struct cmdreadctrl *cmd)
{
	int flag;
	struct socket *s;
	int sid = cmd->sid;
	int enable = cmd->ctrl;
	s = &ss->socketpool[HASH(sid)];
	if (s->reading == enable)
		return;
	s->reading = enable;
	flag = (!wlist_empty(s) || s->type == STYPE_CONNECTING) ? SP_OUT : 0;
	if (enable != 0)
		flag |= SP_IN;
	sp_ctrl(ss->spfd, s->fd, s, flag);
}

static inline int checkconnected(struct silly_socket *ss, struct socket *s)
{
	int ret, err;
	socklen_t errlen = sizeof(err);
	assert(s->fd >= 0);
	ret = getsockopt(s->fd, SOL_SOCKET, SO_ERROR, (void *)&err, &errlen);
	if (unlikely(ret < 0)) {
		err = errno;
		silly_log_error("[socket] checkconnected:%s\n",
				strerror(errno));
		goto err;
	}
	if (unlikely(err != 0)) {
		err = translate_socket_errno(err);
		silly_log_error("[socket] checkconnected:%s\n", strerror(err));
		goto err;
	}
	if (wlist_empty(s))
		write_enable(ss, s, 0);
	return 0;
err:
	//occurs error
	report_close(ss, s, err);
	freesocket(ss, s);
	return -1;
}

static void report_connected(struct silly_socket *ss, struct socket *s)
{
	if (checkconnected(ss, s) < 0)
		return;
	struct silly_message_socket *sc;
	sc = silly_malloc(sizeof(*sc));
	sc->type = SILLY_SCONNECTED;
	sc->sid = s->sid;
	silly_worker_push(tocommon(sc));
	ss->netstat.tcpclient++;
	return;
}

static ssize_t readn(fd_t fd, uint8_t *buf, size_t sz)
{
	for (;;) {
		ssize_t len;
		len = recv(fd, (void *)buf, sz, 0);
		if (len < 0) {
			switch (errno) {
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

static ssize_t sendn(fd_t fd, const uint8_t *buf, size_t sz)
{
	for (;;) {
		ssize_t len;
		len = send(fd, (void *)buf, sz, 0);
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

static ssize_t readudp(fd_t fd, uint8_t *buf, size_t sz,
		       union sockaddr_full *addr, socklen_t *addrlen)
{
	ssize_t n;
	for (;;) {
		n = recvfrom(fd, (void *)buf, sz, 0, (struct sockaddr *)addr,
			     addrlen);
		if (n >= 0)
			return n;
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

static ssize_t sendudp(fd_t fd, uint8_t *data, size_t sz,
		       const union sockaddr_full *addr)
{
	ssize_t n;
	socklen_t sa_len;
	const struct sockaddr *sa;
	if (addr != NULL) {
		sa = &addr->sa;
		sa_len = SA_LEN(*sa);
	} else {
		sa = NULL;
		sa_len = 0;
	}
	for (;;) {
		n = sendto(fd, (void *)data, sz, 0, sa, sa_len);
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

static int forward_msg_tcp(struct silly_socket *ss, struct socket *s)
{
	ssize_t sz;
	ssize_t presize = s->presize;
	uint8_t *buf = (uint8_t *)silly_malloc(presize);
	sz = readn(s->fd, buf, presize);
	//half close socket need no data
	if (sz > 0 && s->type != STYPE_SHUTDOWN) {
		report_data(ss, s, SILLY_SDATA, buf, sz);
		//to predict the pakcet size
		if (sz == presize) {
			s->presize *= 2;
		} else if (presize > MIN_READBUF_LEN) {
			//s->presize at leatest is 2 * MIN_READBUF_LEN
			int half = presize / 2;
			if (sz < half)
				s->presize = half;
		}
		ss->netstat.recvsize += sz;
	} else {
		silly_free(buf);
		if (sz < 0) {
			report_close(ss, s, errno);
			freesocket(ss, s);
			return -1;
		}
		ss->netstat.recvsize += sz;
		return 0;
	}
	return sz;
}

static int forward_msg_udp(struct silly_socket *ss, struct socket *s)
{
	uint8_t *data;
	ssize_t n, sa_len;
	union sockaddr_full addr;
	uint8_t udpbuf[MAX_UDP_PACKET];
	socklen_t len = sizeof(addr);
	n = readudp(s->fd, udpbuf, MAX_UDP_PACKET, &addr, &len);
	if (n < 0)
		return 0;
	sa_len = SA_LEN(addr.sa);
	data = (uint8_t *)silly_malloc(n + sa_len);
	memcpy(data, udpbuf, n);
	memcpy(data + n, &addr, sa_len);
	report_data(ss, s, SILLY_SUDP, data, n);
	ss->netstat.recvsize += n;
	return n;
}

int silly_socket_salen(const void *data)
{
	union sockaddr_full *addr;
	addr = (union sockaddr_full *)data;
	return SA_LEN(addr->sa);
}

int silly_socket_ntop(const void *data, char name[SOCKET_NAMELEN])
{
	union sockaddr_full *addr;
	addr = (union sockaddr_full *)data;
	return ntop(addr, name);
}

void silly_socket_readctrl(int sid, int flag)
{
	struct socket *s;
	struct cmdreadctrl cmd;
	s = &SSOCKET->socketpool[HASH(sid)];
	if (s->type != STYPE_SOCKET)
		return;
	cmd.type = 'R';
	cmd.sid = sid;
	cmd.ctrl = flag;
	pipe_blockwrite(SSOCKET->ctrlsendfd, &cmd, sizeof(cmd));
	return;
}

int silly_socket_sendsize(int sid)
{
	int size = 0;
	struct wlist *w;
	struct socket *s;
	s = &SSOCKET->socketpool[HASH(sid)];
	if (s->type != STYPE_SOCKET)
		return size;
	for (w = s->wlhead; w != NULL; w = w->next)
		size += w->size;
	size -= s->wloffset;
	return size;
}

static int send_msg_tcp(struct silly_socket *ss, struct socket *s)
{
	struct wlist *w;
	w = s->wlhead;
	assert(w);
	while (w) {
		ssize_t sz;
		assert(w->size > s->wloffset);
		sz = sendn(s->fd, w->buf + s->wloffset, w->size - s->wloffset);
		if (unlikely(sz < 0)) {
			report_close(ss, s, errno);
			freesocket(ss, s);
			return -1;
		}
		s->wloffset += sz;
		if (s->wloffset < w->size) //send some
			break;
		assert((size_t)s->wloffset == w->size);
		s->wloffset = 0;
		s->wlhead = w->next;
		w->finalizer(w->buf);
		silly_free(w);
		w = s->wlhead;
		if (w == NULL) { //send ok
			s->wltail = &s->wlhead;
			write_enable(ss, s, 0);
			if (s->type == STYPE_SHUTDOWN) {
				freesocket(ss, s);
				return -1;
			}
		}
	}
	return 0;
}

static int send_msg_udp(struct silly_socket *ss, struct socket *s)
{
	struct wlist *w;
	w = s->wlhead;
	assert(w);
	while (w) {
		ssize_t sz;
		sz = sendudp(s->fd, w->buf, w->size, w->udpaddress);
		if (sz == -2) //EAGAIN, so block it
			break;
		assert(sz == -1 || (size_t)sz == w->size);
		//send fail && send ok will clear
		s->wlhead = w->next;
		w->finalizer(w->buf);
		silly_free(w);
		w = s->wlhead;
		if (w == NULL) { //send all
			s->wltail = &s->wlhead;
			write_enable(ss, s, 0);
			if (s->type == STYPE_SHUTDOWN) {
				freesocket(ss, s);
				return -1;
			}
		}
	}
	return 0;
}

struct addrinfo *getsockaddr(int protocol, const char *ip, const char *port)
{
	int err;
	struct addrinfo hints, *res;
	memset(&hints, 0, sizeof(hints));
	hints.ai_flags = AI_NUMERICHOST;
	hints.ai_family = AF_UNSPEC;
	if (protocol == IPPROTO_TCP)
		hints.ai_socktype = SOCK_STREAM;
	else
		hints.ai_socktype = SOCK_DGRAM;
	hints.ai_protocol = protocol;
	if ((err = getaddrinfo(ip, port, &hints, &res))) {
		set_errmsg(SSOCKET, gai_strerror(err));
		silly_log_error("[socket] bindfd ip:%s port:%s err:%s\n", ip,
				port, gai_strerror(err));
		return NULL;
	}
	return res;
}

static int bindfd(fd_t fd, int protocol, const char *ip, const char *port)
{
	int err;
	struct addrinfo *info;
	if (ip[0] == '\0' && port[0] == '0')
		return 0;
	info = getsockaddr(protocol, ip, port);
	if (info == NULL)
		return -1;
	err = bind(fd, info->ai_addr, info->ai_addrlen);
	if (err < 0) {
		set_errmsg(SSOCKET, strerror(errno));
		silly_log_error("[socket] bindfd ip:%s port:%s err:%s\n", ip,
				port, strerror(errno));
	}
	freeaddrinfo(info);
	return err;
}

static int dolisten(const char *ip, const char *port, int backlog)
{
	int err;
	fd_t fd = -1;
	int reuse = 1;
	struct addrinfo *info = NULL;
	info = getsockaddr(IPPROTO_TCP, ip, port);
	if (unlikely(info == NULL))
		return -1;
	fd = socket(info->ai_family, SOCK_STREAM, 0);
	if (unlikely(fd < 0)) {
		set_errmsg(SSOCKET, strerror(errno));
		goto end;
	}
	setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, (void *)&reuse, sizeof(reuse));
	err = bind(fd, info->ai_addr, info->ai_addrlen);
	if (unlikely(err < 0)) {
		snprintf(SSOCKET->errmsg, sizeof(SSOCKET->errmsg), "%s",
			 strerror(errno));
		goto end;
	}
	nonblock(fd);
	err = listen(fd, backlog);
	if (unlikely(err < 0)) {
		set_errmsg(SSOCKET, strerror(errno));
		goto end;
	}
	freeaddrinfo(info);
	return fd;
end:
	freeaddrinfo(info);
	if (fd >= 0)
		closesocket(fd);
	silly_log_error("[socket] dolisten error:%s\n", strerror(errno));
	return -1;
}

const char *silly_socket_lasterror()
{
	return SSOCKET->errmsg;
}

int silly_socket_listen(const char *ip, const char *port, int backlog)
{
	fd_t fd;
	struct socket *s;
	struct cmdlisten cmd;
	reset_errmsg(SSOCKET);
	fd = dolisten(ip, port, backlog);
	if (unlikely(fd < 0))
		return -errno;
	s = allocsocket(SSOCKET, fd, STYPE_ALLOCED, PROTOCOL_TCP);
	if (unlikely(s == NULL)) {
		silly_log_error("[socket] listen %s:%s:%d allocsocket fail\n",
				ip, port, backlog);
		closesocket(fd);
		return -1;
	}
	cmd.type = 'L';
	cmd.sid = s->sid;
	pipe_blockwrite(SSOCKET->ctrlsendfd, &cmd, sizeof(cmd));
	return s->sid;
}

int silly_socket_udpbind(const char *ip, const char *port)
{
	int err;
	fd_t fd = -1;
	struct cmdlisten cmd;
	struct addrinfo *info;
	const struct socket *s = NULL;
	reset_errmsg(SSOCKET);
	info = getsockaddr(IPPROTO_TCP, ip, port);
	if (info == NULL)
		return -1;
	fd = socket(info->ai_family, SOCK_DGRAM, 0);
	if (unlikely(fd < 0)) {
		set_errmsg(SSOCKET, strerror(errno));
		goto end;
	}
	err = bind(fd, info->ai_addr, info->ai_addrlen);
	if (unlikely(err < 0)) {
		set_errmsg(SSOCKET, strerror(errno));
		goto end;
	}
	nonblock(fd);
	s = allocsocket(SSOCKET, fd, STYPE_ALLOCED, PROTOCOL_UDP);
	if (unlikely(s == NULL)) {
		silly_log_error("[socket] udpbind %s:%s allocsocket fail\n", ip,
				port);
		goto end;
	}
	freeaddrinfo(info);
	cmd.type = 'B';
	cmd.sid = s->sid;
	pipe_blockwrite(SSOCKET->ctrlsendfd, &cmd, sizeof(cmd));
	return s->sid;
end:
	if (fd >= 0)
		closesocket(fd);
	freeaddrinfo(info);
	silly_log_error("[socket] udplisten error:%s\n", strerror(errno));
	return -1;
}

static int trylisten(struct silly_socket *ss, struct cmdlisten *cmd)
{
	int err;
	struct socket *s;
	int sid = cmd->sid;
	s = &ss->socketpool[HASH(sid)];
	assert(s->sid == sid);
	assert(s->type == STYPE_ALLOCED);
	err = sp_add(ss->spfd, s->fd, s);
	if (unlikely(err < 0)) {
		silly_log_error("[socket] trylisten error:%s\n",
				strerror(errno));
		report_close(ss, s, errno);
		closesocket(s->fd);
		freesocket(ss, s);
		return err;
	}
	s->type = STYPE_LISTEN;
	return err;
}

static int tryudpbind(struct silly_socket *ss, struct cmdlisten *cmd)
{
	int err;
	struct socket *s;
	int sid = cmd->sid;
	s = &ss->socketpool[HASH(sid)];
	assert(s->sid == sid);
	assert(s->type == STYPE_ALLOCED);
	err = sp_add(ss->spfd, s->fd, s);
	if (unlikely(err < 0)) {
		silly_log_error("[socket] tryudpbind error:%s\n",
				strerror(errno));
		report_close(ss, s, errno);
		closesocket(s->fd);
		freesocket(ss, s);
		return err;
	}
	assert(s->protocol == PROTOCOL_UDP);
	s->type = STYPE_UDPBIND;
	assert(err == 0);
	return err;
}

int silly_socket_connect(const char *ip, const char *port, const char *bindip,
			 const char *bindport)
{
	int err, fd = -1;
	struct cmdconnect cmd;
	struct addrinfo *info;
	struct socket *s = NULL;
	assert(ip);
	assert(bindip);
	reset_errmsg(SSOCKET);
	info = getsockaddr(IPPROTO_TCP, ip, port);
	if (unlikely(info == NULL))
		return -1;
	fd = socket(info->ai_family, SOCK_STREAM, 0);
	if (unlikely(fd < 0)) {
		set_errmsg(SSOCKET, strerror(errno));
		goto end;
	}
	err = bindfd(fd, IPPROTO_TCP, bindip, bindport);
	if (unlikely(err < 0))
		goto end;
	s = allocsocket(SSOCKET, fd, STYPE_ALLOCED, PROTOCOL_TCP);
	if (unlikely(s == NULL))
		goto end;
	cmd.type = 'C';
	cmd.sid = s->sid;
	memcpy(&cmd.addr, info->ai_addr, info->ai_addrlen);
	pipe_blockwrite(SSOCKET->ctrlsendfd, &cmd, sizeof(cmd));
	freeaddrinfo(info);
	return s->sid;
end:
	if (fd >= 0)
		closesocket(fd);
	freeaddrinfo(info);
	return -1;
}

static void tryconnect(struct silly_socket *ss, struct cmdconnect *cmd)
{
	int err;
	fd_t fd;
	struct socket *s;
	int sid = cmd->sid;
	union sockaddr_full *addr;
	s = &ss->socketpool[HASH(sid)];
	assert(s->fd >= 0);
	assert(s->sid == sid);
	assert(s->type == STYPE_ALLOCED);
	fd = s->fd;
	nonblock(fd);
	keepalive(fd);
	nodelay(fd);
	addr = &cmd->addr;
	err = connect(fd, &addr->sa, SA_LEN(addr->sa));
	if (unlikely(err == -1 && errno != CONNECT_IN_PROGRESS)) { //error
		char namebuf[SOCKET_NAMELEN];
		const char *fmt = "[socket] connect %s,errno:%d\n";
		report_close(ss, s, errno);
		freesocket(ss, s);
		ntop(addr, namebuf);
		silly_log_error(fmt, namebuf, errno);
		return;
	} else if (err == 0) { //connect
		s->type = STYPE_SOCKET;
		err = sp_add(ss->spfd, fd, s);
		if (unlikely(err < 0)) {
			report_close(ss, s, errno);
			freesocket(ss, s);
		} else {
			report_connected(ss, s);
		}
	} else { //block
		s->type = STYPE_CONNECTING;
		err = sp_add(ss->spfd, fd, s);
		if (unlikely(err < 0)) {
			report_close(ss, s, errno);
			freesocket(ss, s);
		} else {
			write_enable(ss, s, 1);
			ss->netstat.connecting++;
		}
	}
	return;
}

int silly_socket_udpconnect(const char *ip, const char *port,
			    const char *bindip, const char *bindport)
{
	int err;
	fd_t fd = -1;
	struct cmdopen cmd;
	struct addrinfo *info;
	struct socket *s = NULL;
	const char *fmt = "[socket] udpconnect %s:%d, errno:%d\n";
	assert(ip);
	assert(bindip);
	reset_errmsg(SSOCKET);
	info = getsockaddr(IPPROTO_UDP, ip, port);
	if (unlikely(info == NULL))
		return -1;
	fd = socket(info->ai_family, SOCK_DGRAM, 0);
	if (unlikely(fd < 0)) {
		set_errmsg(SSOCKET, strerror(errno));
		goto end;
	}
	err = bindfd(fd, IPPROTO_UDP, bindip, bindport);
	if (unlikely(err < 0))
		goto end;
	//udp connect will return immediately
	err = connect(fd, info->ai_addr, info->ai_addrlen);
	if (unlikely(err < 0))
		goto end;
	s = allocsocket(SSOCKET, fd, STYPE_SOCKET, PROTOCOL_UDP);
	if (unlikely(s == NULL))
		goto end;
	assert(s->type == STYPE_SOCKET);
	cmd.type = 'O';
	cmd.sid = s->sid;
	pipe_blockwrite(SSOCKET->ctrlsendfd, &cmd, sizeof(cmd));
	freeaddrinfo(info);
	return s->sid;
end:
	if (fd >= 0)
		closesocket(fd);
	freeaddrinfo(info);
	silly_log_error(fmt, ip, port, errno);
	return -1;
}

static void tryudpconnect(struct silly_socket *ss, struct cmdopen *cmd)
{
	int err;
	int sid = cmd->sid;
	struct socket *s = &ss->socketpool[HASH(sid)];
	assert(s->sid == sid);
	assert(s->fd >= 0);
	assert(s->type == STYPE_SOCKET);
	assert(s->protocol == PROTOCOL_UDP);
	err = sp_add(ss->spfd, s->fd, s);
	if (unlikely(err < 0)) {
		report_close(ss, s, errno);
		freesocket(ss, s);
	}
	return;
}

int silly_socket_close(int sid)
{
	int type;
	struct cmdkick cmd;
	struct socket *s = &SSOCKET->socketpool[HASH(sid)];
	if (unlikely(s->sid != sid)) {
		silly_log_error("[socket] silly_socket_close incorrect "
				"socket %d:%d\n",
				sid, s->sid);
		return -1;
	}
	type = s->type;
	if (unlikely(type == STYPE_CTRL)) {
		silly_log_error("[socket] silly_socket_close ctrl socket:%d\n",
				sid);
		return -1;
	}
	if (unlikely(type == STYPE_RESERVE)) {
		silly_log_warn(
			"[socket] silly_socket_close reserve socket:%d\n", sid);
		return -1;
	}
	cmd.type = 'K';
	cmd.sid = sid;
	pipe_blockwrite(SSOCKET->ctrlsendfd, &cmd, sizeof(cmd));
	return 0;
}

static int tryclose(struct silly_socket *ss, struct cmdkick *cmd)
{
	int type;
	int sid = cmd->sid;
	struct socket *s = &ss->socketpool[HASH(sid)];
	if (unlikely(s->sid != sid)) {
		silly_log_error("[socket] tryclose incorrect "
				"socket %d:%d\n",
				sid, s->sid);
		return -1;
	}
	type = s->type;
	if (unlikely(type == STYPE_CTRL || type == STYPE_RESERVE)) {
		silly_log_error("[socket] tryclose unsupport "
				"type %d:%d\n",
				sid, type);
		return -1;
	}
	if (wlist_empty(s)) { //already send all the data, directly close it
		freesocket(ss, s);
		return 0;
	} else {
		s->type = STYPE_SHUTDOWN;
		return -1;
	}
}

int silly_socket_send(int sid, uint8_t *buf, size_t sz,
		      silly_finalizer_t finalizer)
{
	int type;
	struct cmdsend cmd;
	struct socket *s = &SSOCKET->socketpool[HASH(sid)];
	finalizer = finalizer ? finalizer : silly_free;
	if (unlikely(s->sid != sid || s->protocol != PROTOCOL_TCP)) {
		finalizer(buf);
		silly_log_error("[socket] silly_socket_send invalid sid:%d\n",
				sid);
		return -1;
	}
	type = s->type;
	if (unlikely(!(type == STYPE_SOCKET || type == STYPE_CONNECTING ||
		       type == STYPE_ALLOCED))) {
		finalizer(buf);
		silly_log_error("[socket] silly_socket_send incorrect type "
				"sid:%d type:%d\n",
				sid, type);
		return -1;
	}
	if (unlikely(sz == 0)) {
		finalizer(buf);
		return -1;
	}
	cmd.type = 'S';
	cmd.sid = sid;
	cmd.data = buf;
	cmd.size = sz;
	cmd.finalizer = finalizer;
	pipe_blockwrite(SSOCKET->ctrlsendfd, &cmd, sizeof(cmd));
	return 0;
}

int silly_socket_udpsend(int sid, uint8_t *buf, size_t sz, const uint8_t *addr,
			 size_t addrlen, silly_finalizer_t finalizer)
{
	int type;
	struct cmdudpsend cmd;
	struct socket *s = &SSOCKET->socketpool[HASH(sid)];
	finalizer = finalizer ? finalizer : silly_free;
	if (unlikely(s->sid != sid || s->protocol != PROTOCOL_UDP)) {
		finalizer(buf);
		silly_log_error("[socket] silly_socket_send invalid sid:%d\n",
				sid);
		return -1;
	}
	type = s->type;
	if (unlikely(!(type == STYPE_SOCKET || type == STYPE_UDPBIND ||
		       type == STYPE_ALLOCED))) {
		finalizer(buf);
		silly_log_error("[socket] silly_socket_send incorrect type "
				"sid:%d type:%d\n",
				sid, type);
		return -1;
	}
	if (unlikely(type == STYPE_UDPBIND && addr == NULL)) {
		finalizer(buf);
		silly_log_error(
			"[socket] udpsend udpbind must specify dest addr\n");
		return -1;
	}
	cmd.send.type = 'U';
	cmd.send.sid = sid;
	cmd.send.data = buf;
	cmd.send.size = sz;
	cmd.send.finalizer = finalizer;
	if (s->type == STYPE_UDPBIND) { //udp bind socket need sendto address
		assert(addrlen <= sizeof(cmd.addr));
		memcpy(&cmd.addr, addr, addrlen);
	}
	pipe_blockwrite(SSOCKET->ctrlsendfd, &cmd, sizeof(cmd));
	return 0;
}

static int trysend(struct silly_socket *ss, struct cmdsend *cmd)
{
	int sid = cmd->sid;
	uint8_t *data = cmd->data;
	size_t sz = cmd->size;
	silly_finalizer_t finalizer = cmd->finalizer;
	struct socket *s = &ss->socketpool[HASH(sid)];
	if (unlikely(s->sid != sid || s->protocol != PROTOCOL_TCP)) {
		finalizer(data);
		silly_log_error("[socket] trysend incorrect socket "
				"sid:%d:%d type:%d\n",
				sid, s->sid, s->protocol);
		return 0;
	}
	if (unlikely(s->type != STYPE_SOCKET && s->type != STYPE_CONNECTING)) {
		finalizer(data);
		silly_log_error("[socket] trysend incorrect type "
				"sid:%d type:%d\n",
				sid, s->type);
		return 0;
	}
	ss->netstat.sendsize += sz;
	if (wlist_empty(s) && s->type == STYPE_SOCKET) { //try send
		ssize_t n = sendn(s->fd, data, sz);
		if (n < 0) {
			finalizer(data);
			report_close(ss, s, errno);
			freesocket(ss, s);
			return -1;
		} else if ((size_t)n < sz) {
			s->wloffset = n;
			wlist_append(s, data, sz, finalizer);
			write_enable(ss, s, 1);
		} else {
			assert((size_t)n == sz);
			finalizer(data);
		}
	} else {
		wlist_append(s, data, sz, finalizer);
	}
	return 0;
}

static int tryudpsend(struct silly_socket *ss, struct cmdudpsend *cmd)
{
	size_t size;
	uint8_t *data;
	int sid = cmd->send.sid;
	union sockaddr_full *addr;
	silly_finalizer_t finalizer;
	finalizer = cmd->send.finalizer;
	data = cmd->send.data;
	struct socket *s = &ss->socketpool[HASH(sid)];
	if (unlikely(s->sid != sid || s->protocol != PROTOCOL_UDP)) {
		finalizer(data);
		silly_log_error("[socket] tryudpsend incorrect socket "
				"sid:%d:%d type:%d\n",
				sid, s->sid, s->protocol);
		return 0;
	}
	if (unlikely(s->type != STYPE_SOCKET && s->type != STYPE_UDPBIND)) {
		finalizer(data);
		silly_log_error("[socket] tryudpsend incorrect type "
				"sid:%d type:%d\n",
				sid, s->type);
		return 0;
	}
	size = cmd->send.size;
	ss->netstat.sendsize += size;
	if (s->type == STYPE_UDPBIND) {
		//only udp server need address
		addr = &cmd->addr;
	} else {
		addr = NULL;
	}
	if (wlist_empty(s)) { //try send
		ssize_t n = sendudp(s->fd, data, size, addr);
		if (n == -1 || n >= 0) { //occurs error or send ok
			finalizer(data);
			return 0;
		}
		assert(n == -2); //EAGAIN
		wlist_appendudp(s, data, size, finalizer, addr);
		write_enable(ss, s, 1);
	} else {
		wlist_appendudp(s, data, size, finalizer, addr);
	}
	return 0;
}

void silly_socket_terminate()
{
	struct cmdterm cmd;
	cmd.type = 'T';
	pipe_blockwrite(SSOCKET->ctrlsendfd, &cmd, sizeof(cmd));
	return;
}

//values of cmdpacket::type
//'L'	--> listen(tcp)
//'B'	--> bind(udp)
//'C'	--> connect(tcp)
//'O'	--> connect(udp)
//'K'	--> close(kick)
//'S'	--> send data(tcp)
//'U'	--> send data(udp)
//'R'   --> read ctrl(udp)
//'T'	--> terminate(exit poll)

static void resize_cmdbuf(struct silly_socket *ss, size_t sz)
{
	ss->cmdcap = sz;
	ss->cmdbuf = (uint8_t *)silly_realloc(ss->cmdbuf, sizeof(uint8_t) * sz);
	return;
}

static int cmd_process(struct silly_socket *ss)
{
	int count;
	int close = 0;
	uint8_t *ptr, *end;
	count = ss->ctrlcount;
	if (count <= 0)
		return close;
	if (count > ss->cmdcap)
		resize_cmdbuf(ss, count);
	pipe_blockread(ss->ctrlrecvfd, ss->cmdbuf, count);
	ptr = ss->cmdbuf;
	end = ptr + count;
	while (ptr < end) {
		struct cmdpacket *cmd = (struct cmdpacket *)ptr;
		switch (cmd->u.type) {
		case 'L':
			trylisten(ss, &cmd->u.listen);
			ptr += sizeof(cmd->u.listen);
			break;
		case 'B':
			tryudpbind(ss, &cmd->u.listen);
			ptr += sizeof(cmd->u.listen);
			break;
		case 'C':
			tryconnect(ss, &cmd->u.connect);
			ptr += sizeof(cmd->u.connect);
			break;
		case 'O':
			tryudpconnect(ss, &cmd->u.open);
			ptr += sizeof(cmd->u.open);
			break;
		case 'K':
			if (tryclose(ss, &cmd->u.kick) == 0)
				close = 1;
			ptr += sizeof(cmd->u.kick);
			break;
		case 'S':
			if (trysend(ss, &cmd->u.send) < 0)
				close = 1;
			ptr += sizeof(cmd->u.send);
			break;
		case 'U':
			//udp socket can only be closed active
			tryudpsend(ss, &cmd->u.udpsend);
			ptr += sizeof(cmd->u.udpsend);
			break;
		case 'R':
			read_enable(ss, &cmd->u.readctrl);
			ptr += sizeof(cmd->u.readctrl);
			break;
		case 'T': //just to return from sp_wait
			return -1;
		default:
			silly_log_error("[socket] cmd_process:"
					"unkonw operation:%d\n",
					cmd->u.type);
			assert(!"oh, no!");
			break;
		}
	}
	return close;
}

static void eventwait(struct silly_socket *ss)
{
	for (;;) {
		ss->eventcount = sp_wait(ss->spfd, ss->eventbuf, ss->eventcap);
		ss->eventindex = 0;
		if (ss->eventcount < 0) {
			silly_log_error("[socket] eventwait:%d\n", errno);
			continue;
		}
		break;
	}
	return;
}

int silly_socket_poll()
{
	int err;
	event_t *e;
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
		e = &ss->eventbuf[ei];
		s = (struct socket *)SP_UD(e);
		if (s == NULL) //the socket event has be cleared
			continue;
		switch (s->type) {
		case STYPE_LISTEN:
			assert(SP_READ(e));
			report_accept(ss, s);
			continue;
		case STYPE_CONNECTING:
			s->type = STYPE_SOCKET;
			report_connected(ss, s);
			ss->netstat.connecting--;
			continue;
		case STYPE_RESERVE:
			silly_log_error("[socket] poll reserve socket\n");
			continue;
		case STYPE_SHUTDOWN:
		case STYPE_SOCKET:
		case STYPE_UDPBIND:
			break;
		case STYPE_CTRL:
			continue;
		default:
			silly_log_error(
				"[socket] poll: unkonw socket type:%d\n",
				s->type);
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
				silly_log_error("[socket] poll:"
						"unsupport protocol:%d\n",
						s->protocol);
				continue;
			}
			//this socket have already occurs error,
			//so ignore the write event
			if (err < 0)
				continue;
		}
		if (SP_WRITE(e)) {
			if (s->protocol == PROTOCOL_TCP)
				err = send_msg_tcp(ss, s);
			else
				err = send_msg_udp(ss, s);
			//this socket have already occurs error,
			//so ignore the error event
			if (err < 0)
				continue;
		}
		if (SP_ERR(e)) {
			report_close(ss, s, 0);
			freesocket(ss, s);
		}
	}
	return 0;
}

static void resize_eventbuf(struct silly_socket *ss, size_t sz)
{
	ss->eventcap = sz;
	ss->eventbuf =
		(event_t *)silly_realloc(ss->eventbuf, sizeof(event_t) * sz);
	return;
}

int silly_socket_init()
{
	int err;
	fd_t spfd = SP_INVALID;
	fd_t fds[2] = { -1, -1 };
	struct socket *s = NULL;
	struct silly_socket *ss = silly_malloc(sizeof(*ss));
	memset(ss, 0, sizeof(*ss));
	socketpool_init(ss);
	spfd = sp_create(EVENT_SIZE);
	if (unlikely(spfd == SP_INVALID))
		goto end;
	s = allocsocket(ss, -1, STYPE_CTRL, PROTOCOL_PIPE);
	assert(s);
	//use the pipe and not the socketpair because
	//the pipe will be automatic
	//when the data size small than PIPE_BUF
	err = pipe(fds);
	if (unlikely(err < 0))
		goto end;
	err = sp_add(spfd, fds[0], s);
	if (unlikely(err < 0))
		goto end;
	ss->spfd = spfd;
	ss->reservefd = open("/dev/null", O_RDONLY);
	ss->ctrlsendfd = fds[1];
	ss->ctrlrecvfd = fds[0];
	ss->ctrlcount = 0;
	ss->eventindex = 0;
	ss->eventcount = 0;
	resize_cmdbuf(ss, CMDBUF_SIZE);
	resize_eventbuf(ss, EVENT_SIZE);
	SSOCKET = ss;
	return 0;
end:
	if (s)
		freesocket(ss, s);
	if (spfd != SP_INVALID)
		sp_free(spfd);
	if (fds[0] >= 0)
		closesocket(fds[0]);
	if (fds[1] >= 0)
		closesocket(fds[1]);
	if (ss)
		silly_free(ss);

	return -errno;
}

void silly_socket_exit()
{
	int i;
	assert(SSOCKET);
	sp_free(SSOCKET->spfd);
	closesocket(SSOCKET->reservefd);
	closesocket(SSOCKET->ctrlsendfd);
	closesocket(SSOCKET->ctrlrecvfd);
	struct socket *s = &SSOCKET->socketpool[0];
	for (i = 0; i < MAX_SOCKET_COUNT; i++) {
		enum stype type = s->type;
		if (type == STYPE_SOCKET || type == STYPE_LISTEN ||
		    type == STYPE_SHUTDOWN) {
			closesocket(s->fd);
		}
		++s;
	}
	silly_free(SSOCKET->cmdbuf);
	silly_free(SSOCKET->eventbuf);
	silly_free(SSOCKET->socketpool);
	silly_free(SSOCKET);
	return;
}

const char *silly_socket_pollapi()
{
	return SOCKET_POLL_API;
}

int silly_socket_ctrlcount()
{
	return SSOCKET->ctrlcount;
}

struct silly_netstat *silly_socket_netstat()
{
	return &SSOCKET->netstat;
}

void silly_socket_socketstat(int sid, struct silly_socketstat *info)
{
	struct socket *s;
	s = &SSOCKET->socketpool[HASH(sid)];
	memset(info, 0, sizeof(*info));
	info->sid = s->sid;
	info->fd = s->fd;
	info->type = stype_name[s->type];
	info->protocol = protocol_name[s->protocol];
	if (s->fd >= 0 && s->protocol != PROTOCOL_PIPE) {
		int namelen;
		socklen_t len;
		union sockaddr_full addr;
		char namebuf[SOCKET_NAMELEN];
		len = sizeof(addr);
		getsockname(s->fd, (struct sockaddr *)&addr, &len);
		namelen = ntop(&addr, namebuf);
		memcpy(info->localaddr, namebuf, namelen);
		if (s->type != STYPE_LISTEN) {
			len = sizeof(addr);
			getpeername(s->fd, (struct sockaddr *)&addr, &len);
			namelen = ntop(&addr, namebuf);
			memcpy((void *)info->remoteaddr, namebuf, namelen);
		} else {
			info->remoteaddr[0] = '*';
			info->remoteaddr[1] = '.';
			info->remoteaddr[2] = '*';
		}
	}
	return;
}
