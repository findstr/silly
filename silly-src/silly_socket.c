#include "silly_conf.h"
#include <assert.h>
#include <stdio.h>
#include <errno.h>
#include <stdlib.h>
#include <fcntl.h>
#include <string.h>
#include <stdatomic.h>

#include "silly.h"
#include "compiler.h"
#include "silly_log.h"
#include "platform.h"
#include "spinlock.h"
#include "silly_worker.h"
#include "silly_malloc.h"
#include "silly_socket.h"

/*
 * === Socket Field Concurrency Rules ===
 *
 * [!!WARNING!!]
 * This socket pool allows lock-free reading **only of the `sid` field**.
 * Direct access by Worker threads to other `struct socket` fields can
 * race with concurrent modifications from the Socket thread.
 * Read the rules below carefully to avoid subtle bugs.
 *
 * --- The Concurrency Model: Optimistic Reads with `sid` Verification ---
 *
 * A `struct socket *s` obtained from `pool_get()` is NOT locked.
 * The Socket thread may free or reuse the socket at any time.
 *
 * Reading any field other than `s->sid` is a data race.
 * For non-pointer fields, this can result in stale or torn reads.
 *
 * Reads by Worker threads are "optimistic" — correctness is ensured
 * because the Socket thread validates `sid` before performing any
 * state-changing operation. The versioned `sid` acts as an optimistic lock.
 *
 * --- The Rule of Safe Interaction ---
 *
 * Worker thread logic must never depend on values from fields other than `s->sid`.
 * Such dependencies are racy and can cause operations to be silently dropped
 * by the Socket thread during `sid` verification.
 *
 * --- Correct Workflow ---
 *
 * To ensure correctness, send commands (with `sid`) to the Socket thread,
 * which safely accesses all socket fields on behalf of Worker threads.
 *
 * --- Optional Optimization (Not Recommended) ---
 *
 * Making socket fields atomic and reading them with sid re-verification
 * might seem attractive, but it cannot guarantee a consistent snapshot
 * of the socket's state.
 *
 * Since `sid` only changes on free, it does not protect against concurrent
 * updates to other fields. Strict correctness requires a full seqlock,
 * which is not implemented here.
 *
 * Therefore, Worker threads should avoid relying on multi-field atomic reads.
 */

#if EAGAIN == EWOULDBLOCK
#define ETRYAGAIN EAGAIN
#else
#define ETRYAGAIN \
EAGAIN:           \
	case EWOULDBLOCK
#endif

#define EVENT_SIZE (128)
#define CMDBUF_SIZE (8 * sizeof(struct op_pkt))
#define MAX_UDP_PACKET (512)
#define SOCKET_POOL_SIZE (1 << SOCKET_POOL_EXP)
#define HASH(sid) (sid & (SOCKET_POOL_SIZE - 1))

#define ARRAY_SIZE(a) (sizeof(a) / sizeof(a[0]))

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
	void (*free)(void *);
	union sockaddr_full *udpaddress;
};

struct socket {
	_Atomic(socket_id_t) sid; //socket descriptor
	fd_t fd;
	uint16_t version;
	unsigned char protocol;
	unsigned char reading;
	enum stype type;
	atomic_uint_least32_t wlbytes;
	uint32_t wloffset;
	struct wlist *wlhead;
	struct wlist **wltail;
	struct socket *next;
};

struct socket_pool {
	spinlock_t lock;
	struct socket slots[SOCKET_POOL_SIZE];
	struct socket *free_head;
	struct socket **free_tail;
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
	struct socket_pool pool;
	//ctrl pipe, call write can be automatic
	//when data less then 64k(from APUE)
	int ctrlsendfd;
	int ctrlrecvfd;
	atomic_int_least32_t ctrlcount;
	int cmdcap;
	uint8_t *cmdbuf;
	//reserve id(for socket fd remap)
	socket_id_t reserveid;
	//netstat
	struct silly_netstat netstat;
	//error message
	char errmsg[256];
	//temp buffer
	uint8_t readbuf[TCP_READ_BUF_SIZE];
};

enum op_type {
	OP_TCP_LISTEN,
	OP_UDP_LISTEN,
	OP_TCP_CONNECT,
	OP_UDP_CONNECT,
	OP_TCP_SEND,
	OP_UDP_SEND,
	OP_READ_ENABLE,
	OP_CLOSE,
	OP_EXIT,
};

struct op_hdr {
	socket_id_t sid;
	uint8_t op;
	uint16_t size;
};

struct op_listen{
	struct op_hdr hdr;
};

struct op_connect {
	struct op_hdr hdr;
	union sockaddr_full addr;
};

struct op_close{
	struct op_hdr hdr;
};

struct op_tcpsend {
	struct op_hdr hdr;
	int size;
	uint8_t *data;
	void (*free)(void *);
};

struct op_udpsend {
	struct op_hdr hdr;
	int size;
	uint8_t *data;
	void (*free)(void *);
	union sockaddr_full addr;
};

struct op_readenable {
	struct op_hdr hdr;
	int ctrl;
};

struct op_exit {
	struct op_hdr hdr;
};

struct op_pkt {
	union {
		struct op_hdr hdr;
		struct op_listen listen;
		struct op_close close;
		struct op_connect connect;
		struct op_tcpsend tcpsend;
		struct op_udpsend udpsend;
		struct op_readenable readenable;
		struct op_exit exit;
	};
};

static struct silly_socket *SSOCKET;

static inline void wlist_append(struct socket *s, uint8_t *buf, size_t size,
					void (*freex)(void *))
{
	struct wlist *w;
	w = (struct wlist *)silly_malloc(sizeof(*w));
	w->size = size;
	w->buf = buf;
	w->free = freex;
	w->next = NULL;
	w->udpaddress = NULL;
	*s->wltail = w;
	s->wltail = &w->next;
	atomic_fetch_add_explicit(&s->wlbytes, size-s->wloffset, memory_order_relaxed);
	return;
}

static inline void wlist_appendudp(struct socket *s, uint8_t *buf, size_t size,
						   void (*freex)(void *),
						   const union sockaddr_full *addr)
{
	int addrsz;
	struct wlist *w;
	addrsz = addr ? SA_LEN(addr->sa) : 0;
	w = (struct wlist *)silly_malloc(sizeof(*w) + addrsz);
	w->size = size;
	w->buf = buf;
	w->free = freex;
	w->next = NULL;
	if (addrsz != 0) {
		w->udpaddress = (union sockaddr_full *)(w + 1);
		memcpy(w->udpaddress, addr, addrsz);
	} else {
		w->udpaddress = NULL;
	}
	*s->wltail = w;
	s->wltail = &w->next;
	atomic_fetch_add_explicit(&s->wlbytes, size, memory_order_relaxed);
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
		t->free(t->buf);
		silly_free(t);
	}
	s->wlhead = NULL;
	s->wltail = &s->wlhead;
	atomic_store_explicit(&s->wlbytes, 0, memory_order_relaxed);
	return;
}

static inline int wlist_empty(struct socket *s)
{
	return s->wlhead == NULL ? 1 : 0;
}

static void socket_default(struct socket *s)
{
	s->fd = -1;
	s->type = STYPE_RESERVE;
	s->wloffset = 0;
	s->protocol = 0;
	s->reading = 0;
	s->wlhead = NULL;
	s->wltail = &s->wlhead;
	s->next = NULL;
	atomic_store_explicit(&s->wlbytes, 0, memory_order_relaxed);
	atomic_store_explicit(&s->sid, -1, memory_order_relaxed);
}

static void pool_init(struct socket_pool *p)
{
	int i;
	spinlock_init(&p->lock);
	p->free_head = NULL;
	p->free_tail = &p->free_head;
	for (i = 0; i < SOCKET_POOL_SIZE; i++) {
		struct socket *s = &p->slots[i];
		socket_default(s);
#ifdef SILLY_TEST
		s->version = UINT16_MAX;
#else
		s->version = 0;
#endif
		*p->free_tail = s;
		p->free_tail = &s->next;
	}
	return;
}

static struct socket *pool_alloc(struct socket_pool *p, fd_t fd,
	enum stype type, unsigned char protocol)
{
	socket_id_t id;
	assert(protocol == PROTOCOL_TCP || protocol == PROTOCOL_UDP ||
	       protocol == PROTOCOL_PIPE);
	spinlock_lock(&p->lock);
	if (p->free_head == NULL) {
		spinlock_unlock(&p->lock);
		silly_log_error("[socket] pool_alloc fail, find no empty entry\n");
		return NULL;
	}
	struct socket *s = p->free_head;
	p->free_head = s->next;
	if (p->free_head == NULL) {
		p->free_tail = &p->free_head;
	}
	spinlock_unlock(&p->lock);
	s->fd = fd;
	s->type = type;
	s->protocol = protocol;
	s->reading = 1;
	id = ((socket_id_t)s->version << SOCKET_POOL_EXP) | (s-&p->slots[0]);
	atomic_store_explicit(&s->sid, id, memory_order_release);
	return s;
}

static void pool_free(struct socket_pool *p, struct socket *s)
{
	wlist_free(s);
	s->version++;
	socket_default(s);
	spinlock_lock(&p->lock);
	*p->free_tail = s;
	p->free_tail = &s->next;
	spinlock_unlock(&p->lock);
}

static inline struct socket *pool_get(struct socket_pool *p, socket_id_t id)
{
	struct socket *s = &p->slots[HASH(id)];
	if (unlikely(atomic_load_explicit(&s->sid, memory_order_acquire) != id))
		return NULL;
	return s;
}

static inline void reset_errmsg(struct silly_socket *ss)
{
	ss->errmsg[0] = '\0';
}

static inline void set_errmsg(struct silly_socket *ss, const char *str)
{
	snprintf(ss->errmsg, sizeof(ss->errmsg), "%s", str);
}

static inline void netstat_close(struct silly_socket *ss, struct socket *s)
{
	if (s->protocol != PROTOCOL_TCP ||
	    (s->type != STYPE_SOCKET && s->type != STYPE_SHUTDOWN)) {
		return;
	}
	ss->netstat.tcpclient--;
}

static inline void freesocket(struct silly_socket *ss, struct socket *s)
{
	if (unlikely(s->type == STYPE_RESERVE)) {
		const char *fmt = "[socket] freesocket sid:%lld error type:%d\n";
		silly_log_error(fmt, s->sid, s->type);
		return;
	}
	if (s->fd >= 0) {
		sp_del(ss->spfd, s->fd);
		closesocket(s->fd);
		s->fd = -1;
	}
	netstat_close(ss, s);
	pool_free(&ss->pool, s);
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
		atomic_fetch_sub_explicit(&SSOCKET->ctrlcount, n, memory_order_relaxed);
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
		atomic_fetch_add_explicit(&SSOCKET->ctrlcount, sz, memory_order_relaxed);
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
	s = pool_alloc(&ss->pool, fd, STYPE_SOCKET, PROTOCOL_TCP);
	if (unlikely(s == NULL)) {
		set_errmsg(ss, "socket pool is full");
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
	sa->listenid = listen->sid;
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
	sc->err = err;
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
	sd->size = sz;
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
	ss->netstat.tcpclient++;
	if (checkconnected(ss, s) < 0)
		return;
	struct silly_message_socket *sc;
	sc = silly_malloc(sizeof(*sc));
	sc->type = SILLY_SCONNECTED;
	sc->sid = s->sid;
	silly_worker_push(tocommon(sc));
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
	sz = readn(s->fd, ss->readbuf, sizeof(ss->readbuf));
	//half close socket need no data
	if (sz > 0 && s->type != STYPE_SHUTDOWN) {
		uint8_t *buf = (uint8_t *)silly_malloc(sz);
		memcpy(buf, ss->readbuf, sz);
		report_data(ss, s, SILLY_SDATA, buf, sz);
		ss->netstat.recvsize += sz;
	} else {
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

void silly_socket_readctrl(socket_id_t sid, int flag)
{
	struct socket *s;
	struct op_readenable op = {0};
	s = pool_get(&SSOCKET->pool, sid);
	if (unlikely(s == NULL))
		return;
	op.hdr.op = OP_READ_ENABLE;
	op.hdr.sid = sid;
	op.hdr.size = sizeof(op);
	op.ctrl = flag;
	pipe_blockwrite(SSOCKET->ctrlsendfd, &op, sizeof(op));
	return;
}

static void op_read_enable(struct silly_socket *ss, struct op_readenable *op, struct socket *s)
{
	int flag;
	int enable = op->ctrl;
	if (s->reading == enable)
		return;
	s->reading = enable;
	flag = (!wlist_empty(s) || s->type == STYPE_CONNECTING) ? SP_OUT : 0;
	if (enable != 0)
		flag |= SP_IN;
	sp_ctrl(ss->spfd, s->fd, s, flag);
}

int silly_socket_sendsize(socket_id_t sid)
{
	struct socket *s;
	s = pool_get(&SSOCKET->pool, sid);
	if (unlikely(s == NULL))
		return 0;
	return atomic_load_explicit(&s->wlbytes, memory_order_relaxed);
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
		atomic_fetch_sub_explicit(&s->wlbytes, sz, memory_order_relaxed);
		if (s->wloffset < w->size) //send some
			break;
		assert((size_t)s->wloffset == w->size);
		s->wloffset = 0;
		s->wlhead = w->next;
		w->free(w->buf);
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
		atomic_fetch_sub_explicit(&s->wlbytes, sz, memory_order_relaxed);
		assert(sz == -1 || (size_t)sz == w->size);
		//send fail && send ok will clear
		s->wlhead = w->next;
		w->free(w->buf);
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

socket_id_t silly_socket_listen(const char *ip, const char *port, int backlog)
{
	fd_t fd;
	struct socket *s;
	struct op_listen op = {0};
	reset_errmsg(SSOCKET);
	fd = dolisten(ip, port, backlog);
	if (unlikely(fd < 0))
		return -errno;
	s = pool_alloc(&SSOCKET->pool, fd, STYPE_ALLOCED, PROTOCOL_TCP);
	if (unlikely(s == NULL)) {
		silly_log_error("[socket] listen %s:%s:%d pool_alloc fail\n",
							ip, port, backlog);
		closesocket(fd);
		return -1;
	}
	op.hdr.op = OP_TCP_LISTEN;
	op.hdr.sid = s->sid;
	op.hdr.size = sizeof(op);
	pipe_blockwrite(SSOCKET->ctrlsendfd, &op, op.hdr.size);
	return s->sid;
}

static int op_tcp_listen(struct silly_socket *ss, struct op_listen *op, struct socket *s)
{
	int err;
	(void)op;
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


socket_id_t silly_socket_udpbind(const char *ip, const char *port)
{
	int err;
	fd_t fd = -1;
	struct op_listen op = {0};
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
	s = pool_alloc(&SSOCKET->pool, fd, STYPE_ALLOCED, PROTOCOL_UDP);
	if (unlikely(s == NULL)) {
		silly_log_error("[socket] udpbind %s:%s pool_alloc fail\n", ip,
							port);
		goto end;
	}
	freeaddrinfo(info);
	op.hdr.op = OP_UDP_LISTEN;
	op.hdr.sid = s->sid;
	op.hdr.size = sizeof(op);
	pipe_blockwrite(SSOCKET->ctrlsendfd, &op, op.hdr.size);
	return s->sid;
end:
	if (fd >= 0)
		closesocket(fd);
	freeaddrinfo(info);
	silly_log_error("[socket] udplisten error:%s\n", strerror(errno));
	return -1;
}

static int op_udp_listen(struct silly_socket *ss, struct op_listen *op, struct socket *s)
{
	int err;
	(void)op;
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

socket_id_t silly_socket_connect(const char *ip, const char *port, const char *bindip,
			 const char *bindport)
{
	int err, fd = -1;
	struct op_connect op = {0};
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
	s = pool_alloc(&SSOCKET->pool, fd, STYPE_ALLOCED, PROTOCOL_TCP);
	if (unlikely(s == NULL))
		goto end;
	op.hdr.op = OP_TCP_CONNECT;
	op.hdr.sid = s->sid;
	op.hdr.size = sizeof(op);
	assert(sizeof(op.addr) >= info->ai_addrlen);
	memcpy(&op.addr, info->ai_addr, info->ai_addrlen);
	pipe_blockwrite(SSOCKET->ctrlsendfd, &op, op.hdr.size);
	freeaddrinfo(info);
	return s->sid;
end:
	if (fd >= 0)
		closesocket(fd);
	freeaddrinfo(info);
	return -1;
}

static void op_tcp_connect(struct silly_socket *ss, struct op_connect *op, struct socket *s)
{
	int err;
	fd_t fd;
	union sockaddr_full *addr;
	assert(s->fd >= 0);
	assert(s->type == STYPE_ALLOCED);
	fd = s->fd;
	nonblock(fd);
	keepalive(fd);
	nodelay(fd);
	addr = &op->addr;
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


socket_id_t silly_socket_udpconnect(const char *ip, const char *port,
			    const char *bindip, const char *bindport)
{
	int err;
	fd_t fd = -1;
	struct op_connect op = {0};
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
	s = pool_alloc(&SSOCKET->pool, fd, STYPE_SOCKET, PROTOCOL_UDP);
	if (unlikely(s == NULL))
		goto end;
	op.hdr.op = OP_UDP_CONNECT;
	op.hdr.sid = s->sid;
	op.hdr.size = sizeof(op);
	pipe_blockwrite(SSOCKET->ctrlsendfd, &op, op.hdr.size);
	freeaddrinfo(info);
	return s->sid;
end:
	if (fd >= 0)
		closesocket(fd);
	freeaddrinfo(info);
	silly_log_error(fmt, ip, port, errno);
	return -1;
}

static void op_udp_connect(struct silly_socket *ss, struct op_connect *op, struct socket *s)
{
	int err;
	(void)op;
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

int silly_socket_close(socket_id_t sid)
{
	struct op_close op = {0};
	struct socket *s = pool_get(&SSOCKET->pool, sid);
	if (unlikely(s == NULL)) {
		silly_log_error("[socket] silly_socket_close invalid sid:%llu\n", sid);
		return -1;
	}
	op.hdr.op = OP_CLOSE;
	op.hdr.sid = sid;
	op.hdr.size = sizeof(op);
	pipe_blockwrite(SSOCKET->ctrlsendfd, &op, op.hdr.size);
	return 0;
}

static int op_tcp_close(struct silly_socket *ss, struct op_close *op, struct socket *s)
{
	int type;
	(void)op;
	type = s->type;
	if (unlikely(type == STYPE_CTRL || type == STYPE_RESERVE)) {
		silly_log_error("[socket] op_tcp_close unsupport type %d\n", type);
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

int silly_socket_send(socket_id_t sid, uint8_t *buf, size_t sz,
		void (*freex)(void *))
{
	struct op_tcpsend op = {0};
	struct socket *s = pool_get(&SSOCKET->pool, sid);
	if (freex == NULL)
		freex = silly_free;
	if (unlikely(s == NULL)) {
		freex(buf);
		silly_log_error("[socket] silly_socket_send invalid sid:%llu\n",
							sid);
		return -1;
	}
	if (unlikely(sz == 0)) {
		freex(buf);
		return -1;
	}
	op.hdr.op = OP_TCP_SEND;
	op.hdr.sid = sid;
	op.hdr.size = sizeof(op);
	op.data = buf;
	op.size = sz;
	op.free = freex;
	pipe_blockwrite(SSOCKET->ctrlsendfd, &op, op.hdr.size);
	return 0;
}

static int op_tcp_send(struct silly_socket *ss, struct op_tcpsend *op, struct socket *s)
{
	uint8_t *data = op->data;
	size_t sz = op->size;
	void (*freex)(void *) = op->free;
	if (unlikely(s->protocol != PROTOCOL_TCP)) {
		freex(data);
		silly_log_error("[socket] op_tcp_send incorrect socket "
							"sid:%llu type:%d\n",
							s->sid, s->protocol);
		return 0;
	}
	if (unlikely(s->type != STYPE_SOCKET && s->type != STYPE_CONNECTING)) {
		freex(data);
		silly_log_error("[socket] op_tcp_send incorrect type "
							"sid:%llu type:%d\n",
							s->sid, s->type);
		return 0;
	}

	ss->netstat.sendsize += sz;
	if (wlist_empty(s) && s->type == STYPE_SOCKET) { //try send
		ssize_t n = sendn(s->fd, data, sz);
		if (n < 0) {
			freex(data);
			report_close(ss, s, errno);
			freesocket(ss, s);
			return -1;
		} else if ((size_t)n < sz) {
			s->wloffset = n;
			wlist_append(s, data, sz, freex);
			write_enable(ss, s, 1);
		} else {
			assert((size_t)n == sz);
			freex(data);
		}
	} else {
		wlist_append(s, data, sz, freex);
	}
	return 0;
}

int silly_socket_udpsend(socket_id_t sid, uint8_t *buf, size_t sz, const uint8_t *addr,
			 size_t addrlen, void (*freex)(void *))
{
	struct op_udpsend op = {0};
	struct socket *s = pool_get(&SSOCKET->pool, sid);
	freex = freex ? freex : silly_free;
	if (unlikely(s == NULL)) {
		freex(buf);
		silly_log_error("[socket] silly_socket_send invalid sid:%llu\n",
							sid);
		return -1;
	}
	op.hdr.op = OP_UDP_SEND;
	op.hdr.sid = sid;
	op.hdr.size = sizeof(op);
	op.data = buf;
	op.size = sz;
	op.free = freex;
	if (s->type == STYPE_UDPBIND) { //udp bind socket need sendto address
		assert(addrlen <= sizeof(op.addr));
		memcpy(&op.addr, addr, addrlen);
	}
	pipe_blockwrite(SSOCKET->ctrlsendfd, &op, op.hdr.size);
	return 0;
}

static int op_udp_send(struct silly_socket *ss, struct op_udpsend *op, struct socket *s)
{
	size_t size;
	uint8_t *data;
	union sockaddr_full *addr;
	data = op->data;
	void (*freex)(void *) = op->free;
	if (unlikely(s->protocol != PROTOCOL_UDP)) {
		freex(data);
		silly_log_error("[socket] op_udp_send incorrect socket "
							"sid:%llu type:%d\n",
							s->sid, s->protocol);
		return 0;
	}
	if (unlikely(s->type != STYPE_SOCKET && s->type != STYPE_UDPBIND)) {
		freex(data);
		silly_log_error("[socket] op_udp_send incorrect type "
							"sid:%llu type:%d\n",
							s->sid, s->type);
		return 0;
	}

	size = op->size;
	ss->netstat.sendsize += size;
	if (s->type == STYPE_UDPBIND) {
		//only udp server need address
		addr = &op->addr;
	} else {
		addr = NULL;
	}
	if (wlist_empty(s)) { //try send
		ssize_t n = sendudp(s->fd, data, size, addr);
		if (n == -1 || n >= 0) { //occurs error or send ok
			freex(data);
			return 0;
		}
		assert(n == -2); //EAGAIN
		wlist_appendudp(s, data, size, freex, addr);
		write_enable(ss, s, 1);
	} else {
		wlist_appendudp(s, data, size, freex, addr);
	}
	return 0;
}

void silly_socket_terminate()
{
	struct op_exit op = {0};
	op.hdr.op = OP_EXIT;
	op.hdr.sid = 0;
	op.hdr.size = sizeof(op);
	pipe_blockwrite(SSOCKET->ctrlsendfd, &op, op.hdr.size);
	return;
}

static void resize_cmdbuf(struct silly_socket *ss, size_t sz)
{
	ss->cmdcap = sz;
	ss->cmdbuf = (uint8_t *)silly_realloc(ss->cmdbuf, sizeof(uint8_t) * sz);
	return;
}

static int op_process(struct silly_socket *ss)
{
	int count;
	int close = 0;
	uint8_t *ptr, *end;
	count = atomic_load_explicit(&ss->ctrlcount, memory_order_relaxed);
	if (count <= 0)
		return close;
	if (count > ss->cmdcap)
		resize_cmdbuf(ss, count);
	pipe_blockread(ss->ctrlrecvfd, ss->cmdbuf, count);
	ptr = ss->cmdbuf;
	end = ptr + count;
	while (ptr < end) {
		struct socket *s;
		struct op_pkt *op = (struct op_pkt *)ptr;
		if (op->hdr.op == OP_EXIT)
			return -1;
		assert(op->hdr.size > 0);
		ptr += op->hdr.size;
		s = pool_get(&ss->pool, op->hdr.sid);
		if (s == NULL) {
			silly_log_error("[socket] op_process sid:%llu invalid\n",
							op->hdr.sid);
			continue;
		}
		switch (op->hdr.op) {
		case OP_TCP_LISTEN:
			op_tcp_listen(ss, &op->listen, s);
			break;
		case OP_UDP_LISTEN:
			op_udp_listen(ss, &op->listen, s);
			break;
		case OP_TCP_CONNECT:
			op_tcp_connect(ss, &op->connect, s);
			break;
		case OP_UDP_CONNECT:
			op_udp_connect(ss, &op->connect, s);
			break;
		case OP_CLOSE:
			if (op_tcp_close(ss, &op->close, s) == 0)
				close = 1;
			break;
		case OP_TCP_SEND:
			if (op_tcp_send(ss, &op->tcpsend, s) < 0)
				close = 1;
			break;
		case OP_UDP_SEND:
			//udp socket can only be closed active
			op_udp_send(ss, &op->udpsend, s);
			break;
		case OP_READ_ENABLE:
			op_read_enable(ss, &op->readenable, s);
			break;
		default:
			silly_log_error("[socket] op_process:"
					"unkonw operation:%d\n",
					op->hdr.op);
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
	err = op_process(ss);
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
	pool_init(&ss->pool);
	spfd = sp_create(EVENT_SIZE);
	if (unlikely(spfd == SP_INVALID))
		goto end;
	s = pool_alloc(&ss->pool, -1, STYPE_CTRL, PROTOCOL_PIPE);
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
	atomic_store_explicit(&ss->ctrlcount, 0, memory_order_relaxed);
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
	struct socket *s = &SSOCKET->pool.slots[0];
	for (i = 0; i < SOCKET_POOL_SIZE; i++) {
		enum stype type = s->type;
		if (type == STYPE_SOCKET || type == STYPE_LISTEN ||
		    type == STYPE_SHUTDOWN) {
			closesocket(s->fd);
		}
		++s;
	}
	silly_free(SSOCKET->cmdbuf);
	silly_free(SSOCKET->eventbuf);
	silly_free(SSOCKET);
	return;
}

const char *silly_socket_pollapi()
{
	return SOCKET_POLL_API;
}

int silly_socket_ctrlcount()
{
	return atomic_load_explicit(&SSOCKET->ctrlcount, memory_order_relaxed);
}

void silly_socket_netstat(struct silly_netstat *stat)
{
	stat->connecting = atomic_load_explicit(&SSOCKET->netstat.connecting, memory_order_relaxed);
	stat->tcpclient = atomic_load_explicit(&SSOCKET->netstat.tcpclient, memory_order_relaxed);
	stat->recvsize = atomic_load_explicit(&SSOCKET->netstat.recvsize, memory_order_relaxed);
	stat->sendsize = atomic_load_explicit(&SSOCKET->netstat.sendsize, memory_order_relaxed);
	return;
}

// NOTE: This function uses an optimistic read pattern. It is not guaranteed
// to be fully consistent and may return a snapshot of fields read at slightly
// different moments. For its intended, non-critical monitoring purpose, this
// trade-off for lower latency is considered acceptable.
void silly_socket_socketstat(socket_id_t sid, struct silly_socketstat *info)
{
	struct socket *s;
	memset(info, 0, sizeof(*info));
	s = pool_get(&SSOCKET->pool, sid);
	if (s == NULL) {
		silly_log_error("[socket] silly_socket_socketstat sid:%llu invalid\n", sid);
		return;
	}
	int fd = s->fd;
	int type = s->type;
	int protocol = s->protocol;
	s = pool_get(&SSOCKET->pool, sid);
	if (s == NULL) {
		silly_log_error("[socket] silly_socket_socketstat sid:%llu invalid\n", sid);
		return;
	}
	info->sid = sid;
	info->fd = fd;
	info->type = stype_name[type];
	info->protocol = protocol_name[protocol];
	if (info->fd >= 0 && protocol != PROTOCOL_PIPE) {
		int namelen;
		socklen_t len;
		union sockaddr_full addr;
		char namebuf[SOCKET_NAMELEN];
		len = sizeof(addr);
		getsockname(info->fd, (struct sockaddr *)&addr, &len);
		namelen = ntop(&addr, namebuf);
		memcpy(info->localaddr, namebuf, namelen);
		if (type != STYPE_LISTEN) {
			len = sizeof(addr);
			getpeername(fd, (struct sockaddr *)&addr, &len);
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

