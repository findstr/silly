#include "silly_conf.h"
#include <assert.h>
#include <stdio.h>
#include <errno.h>
#include <stdlib.h>
#include <fcntl.h>
#include <string.h>
#include <stdatomic.h>

#include "silly.h"
#include "platform.h"
#include "sockaddr.h"
#include "message.h"
#include "compiler.h"
#include "errnoex.h"
#include "silly_log.h"
#include "platform.h"
#include "spinlock.h"
#include "trigger.h"
#include "flipbuf.h"
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
#define MAX_UDP_PACKET (512)
#define SOCKET_POOL_SIZE (1 << SOCKET_POOL_EXP)
#define HASH(sid) (sid & (SOCKET_POOL_SIZE - 1))

#define ARRAY_SIZE(a) (sizeof(a) / sizeof(a[0]))

#define STATE_POLLING (1 << 0)
#define STATE_PENDING (1 << 1)
#define STATE_CONNECTING STATE_PENDING
#define STATE_LISTENING STATE_PENDING
#define STATE_READING (1 << 2)
#define STATE_WRITING (1 << 3)
#define STATE_CLOSING (1 << 4)
#define STATE_MUTECLOSE (1 << 5)
#define STATE_ZOMBINE (1 << 6)

#define test_state(s, sx) \
	((atomic_load_explicit(&(s)->state, memory_order_acquire) & (sx)) != 0)
#define set_state(s, sx) \
	atomic_fetch_or_explicit(&(s)->state, (sx), memory_order_release)
#define clr_state(s, sx) \
	atomic_fetch_and_explicit(&(s)->state, ~(sx), memory_order_release)

#define is_polling(s) test_state(s, STATE_POLLING)
#define is_connecting(s) test_state(s, STATE_CONNECTING)
#define is_listening(s) test_state(s, STATE_LISTENING)
#define is_reading(s) test_state(s, STATE_READING)
#define is_writing(s) test_state(s, STATE_WRITING)
#define is_closing(s) test_state(s, STATE_CLOSING)
#define is_muteclose(s) test_state(s, STATE_MUTECLOSE)
#define is_zombine(s) test_state(s, STATE_ZOMBINE)

#define set_connecting(s) set_state(s, STATE_CONNECTING)
#define set_listening(s) set_state(s, STATE_LISTENING)
#define set_reading(s) set_state(s, STATE_READING)
#define set_writing(s) set_state(s, STATE_WRITING)
#define set_muteclose(s) set_state(s, STATE_MUTECLOSE)
#define set_zombine(s) set_state(s, STATE_ZOMBINE)

#define clr_connecting(s) clr_state(s, STATE_CONNECTING)
#define clr_listening(s) clr_state(s, STATE_LISTENING)
#define clr_reading(s) clr_state(s, STATE_READING)
#define clr_writing(s) clr_state(s, STATE_WRITING)
#define clr_zombine(s) clr_state(s, STATE_ZOMBINE)

#define PROTOCOL_TCP 1
#define PROTOCOL_UDP 2
#define PROTOCOL_PIPE 3

#define SOCKET_RESERVE 0
#define SOCKET_LISTEN 1
#define SOCKET_CONNECTION 2
#define SOCKET_CTRL 3

#define make_type(protocol, type) ((protocol) << 4 | (type))

#define SOCKET_PIPE_CTRL make_type(PROTOCOL_PIPE, SOCKET_CTRL)
#define SOCKET_TCP_LISTEN make_type(PROTOCOL_TCP, SOCKET_LISTEN)
#define SOCKET_UDP_LISTEN make_type(PROTOCOL_UDP, SOCKET_LISTEN)
#define SOCKET_TCP_CONNECTION make_type(PROTOCOL_TCP, SOCKET_CONNECTION)
#define SOCKET_UDP_CONNECTION make_type(PROTOCOL_UDP, SOCKET_CONNECTION)

#define socket_type(s) (s->type & 0x0f)
#define socket_protocol(s) ((s->type >> 4) & 0x0f)

#define sid(s) atomic_load_explicit(&(s)->sid, memory_order_acquire)

#define atomic_add(ptr, val) \
	atomic_fetch_add_explicit(ptr, (val), memory_order_relaxed)
#define atomic_sub(ptr, val) \
	atomic_fetch_sub_explicit(ptr, (val), memory_order_relaxed)

static const char *protocol_name[] = {
	"INVALID",
	"TCP",
	"UDP",
	"PIPE",
};

static const char *stype_name[] = {
	"RESERVE",
	"LISTEN",
	"CONNECTION",
	"CTRL",
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
	uint32_t version;
	uint8_t type;
	atomic_uint_least8_t state;
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
	//ctrl trigger for worker-socket thread communication
	struct trigger ctrl;
	struct flipbuf opbuf;
	//reserve id(for socket fd remap)
	socket_id_t reserveid;
	//netstat
	struct silly_netstat netstat;
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

struct op_listen {
	struct op_hdr hdr;
};

struct op_connect {
	struct op_hdr hdr;
	union sockaddr_full addr;
};

struct op_close {
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

struct message_connect {
	struct silly_message hdr;
	socket_id_t sid;
	int err;
};

struct message_listen {
	struct silly_message hdr;
	socket_id_t sid;
	int err;
};

struct message_accept {
	struct silly_message hdr;
	socket_id_t sid;
	socket_id_t listenid;
	uint8_t *addr;
};

struct message_tcpdata {
	struct silly_message hdr;
	socket_id_t sid;
	size_t size;
	uint8_t *ptr;
};

struct message_udpdata {
	struct silly_message hdr;
	socket_id_t sid;
	size_t size;
	uint8_t *ptr;
	union sockaddr_full addr;
};

struct message_close {
	struct silly_message hdr;
	socket_id_t sid;
	int err;
};

struct silly_socket_msgtype MSG_TYPE = { 0 };
static struct silly_socket *SSOCKET;

static inline void wlist_append(struct socket *s, uint8_t *buf, size_t size,
				void (*freex)(void *))
{
	struct wlist *w;
	w = (struct wlist *)mem_alloc(sizeof(*w));
	w->size = size;
	w->buf = buf;
	w->free = freex;
	w->next = NULL;
	w->udpaddress = NULL;
	*s->wltail = w;
	s->wltail = &w->next;
	return;
}

static inline void wlist_appendudp(struct socket *s, uint8_t *buf, size_t size,
				   void (*freex)(void *),
				   const union sockaddr_full *addr)
{
	int addrsz;
	struct wlist *w;
	addrsz = sockaddr_len(addr);
	w = (struct wlist *)mem_alloc(sizeof(*w) + addrsz);
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
		mem_free(t);
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
	s->type = SOCKET_RESERVE;
	s->wloffset = 0;
	atomic_store_explicit(&s->state, 0, memory_order_relaxed);
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
		atomic_init(&s->sid, -1);
		atomic_init(&s->state, 0);
		atomic_init(&s->wlbytes, 0);
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

static struct socket *pool_alloc(struct socket_pool *p, fd_t fd, int type)
{
	socket_id_t id;
	spinlock_lock(&p->lock);
	if (p->free_head == NULL) {
		spinlock_unlock(&p->lock);
		log_error("[socket] pool_alloc fail, find no empty entry\n");
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
	id = ((socket_id_t)s->version << SOCKET_POOL_EXP) | (s - &p->slots[0]);
	atomic_store_explicit(&s->sid, id, memory_order_release);
	return s;
}

static void pool_free(struct socket_pool *p, struct socket *s)
{
	assert(wlist_empty(s));
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
	if (unlikely(sid(s) != id))
		return NULL;
	return s;
}

static int ntop(const union sockaddr_full *addr,
		char namebuf[SILLY_SOCKET_NAMELEN])
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
	namelen += snprintf(&buf[namelen], SILLY_SOCKET_NAMELEN - namelen,
			    ":%d", port);
	return namelen;
}

static int accept_unpack(lua_State *L, struct silly_message *m)
{
	struct message_accept *ma = container_of(m, struct message_accept, hdr);
	int addrlen = *ma->addr;
	char *addr = (char *)ma->addr + 1;
	lua_pushinteger(L, ma->sid);
	lua_pushinteger(L, ma->listenid);
	lua_pushlstring(L, addr, addrlen);
	return 3;
}

static int listen_unpack(lua_State *L, struct silly_message *m)
{
	struct message_listen *ml = container_of(m, struct message_listen, hdr);
	lua_pushinteger(L, ml->sid);
	worker_push_error(L, 0, ml->err);
	return 2;
}

static int connect_unpack(lua_State *L, struct silly_message *m)
{
	struct message_connect *mc =
		container_of(m, struct message_connect, hdr);
	lua_pushinteger(L, mc->sid);
	worker_push_error(L, 0, mc->err);
	return 2;
}

static int close_unpack(lua_State *L, struct silly_message *m)
{
	struct message_close *mc = container_of(m, struct message_close, hdr);
	lua_pushinteger(L, mc->sid);
	worker_push_error(L, 0, mc->err);
	return 2;
}

static int tcpdata_unpack(lua_State *L, struct silly_message *m)
{
	struct message_tcpdata *md =
		container_of(m, struct message_tcpdata, hdr);
	lua_pushinteger(L, md->sid);
	lua_pushlightuserdata(L, md->ptr);
	lua_pushinteger(L, md->size);
	md->ptr = NULL;
	return 3;
}

static void tcpdata_free(void *m)
{
	struct message_tcpdata *md =
		container_of(m, struct message_tcpdata, hdr);
	if (unlikely(md->ptr != NULL)) {
		mem_free(md->ptr);
	}
	mem_free(md);
}

static int udpdata_unpack(lua_State *L, struct silly_message *m)
{
	struct message_udpdata *md =
		container_of(m, struct message_udpdata, hdr);
	lua_pushinteger(L, md->sid);
	lua_pushlightuserdata(L, md->ptr);
	lua_pushinteger(L, md->size);
	lua_pushlstring(L, (char *)&md->addr, sockaddr_len(&md->addr));
	md->ptr = NULL;
	return 4;
}

static void udpdata_free(void *m)
{
	struct message_udpdata *md =
		container_of(m, struct message_udpdata, hdr);
	if (unlikely(md->ptr != NULL)) {
		mem_free(md->ptr);
	}
	mem_free(md);
}

static void report_accept(struct silly_socket *ss, struct socket *listen,
			  struct socket *s, const union sockaddr_full *addr)
{
	(void)ss;
	char namebuf[SILLY_SOCKET_NAMELEN];
	struct message_accept *ma;
	int namelen = ntop(addr, namebuf);
	ma = mem_alloc(sizeof(*ma) + namelen + 1);
	ma->hdr.type = MSG_TYPE.accept;
	ma->hdr.unpack = accept_unpack;
	ma->hdr.free = mem_free;
	ma->sid = s->sid;
	ma->listenid = listen->sid;
	ma->addr = (uint8_t *)(ma + 1);
	*ma->addr = namelen;
	memcpy(ma->addr + 1, namebuf, namelen);
	worker_push(&ma->hdr);
}

static void report_listen(struct silly_socket *ss, struct socket *s, int err)
{
	(void)ss;
	struct message_listen *ml;
	ml = mem_alloc(sizeof(*ml));
	ml->hdr.type = MSG_TYPE.listen;
	ml->hdr.unpack = listen_unpack;
	ml->hdr.free = mem_free;
	ml->sid = s->sid;
	ml->err = err;
	worker_push(&ml->hdr);
	return;
}

static void report_close(struct silly_socket *ss, struct socket *s, int err)
{
	(void)ss;
	struct message_close *mc;
	if (is_muteclose(s))
		return;
	set_muteclose(s); // Ensure the close event is emitted only once
	assert(s->type == SOCKET_TCP_CONNECTION);
	mc = mem_alloc(sizeof(*mc));
	mc->hdr.type = MSG_TYPE.close;
	mc->hdr.unpack = close_unpack;
	mc->hdr.free = mem_free;
	mc->sid = s->sid;
	mc->err = err;
	worker_push(&mc->hdr);
	return;
}

static void report_tcpdata(struct silly_socket *ss, struct socket *s,
			   uint8_t *data, size_t sz)
{
	(void)ss;
	assert(s->type == SOCKET_TCP_CONNECTION);
	struct message_tcpdata *md = mem_alloc(sizeof(*md));
	md->hdr.type = MSG_TYPE.tcpdata;
	md->hdr.unpack = tcpdata_unpack;
	md->hdr.free = tcpdata_free;
	md->sid = s->sid;
	md->size = sz;
	md->ptr = data;
	worker_push(&md->hdr);
	return;
};

static void report_udpdata(struct silly_socket *ss, struct socket *s,
			   uint8_t *data, size_t sz,
			   const union sockaddr_full *addr)
{
	(void)ss;
	assert(s->type == SOCKET_UDP_CONNECTION ||
	       s->type == SOCKET_UDP_LISTEN);
	struct message_udpdata *md = mem_alloc(sizeof(*md));
	md->hdr.type = MSG_TYPE.udpdata;
	md->hdr.unpack = udpdata_unpack;
	md->hdr.free = udpdata_free;
	md->sid = s->sid;
	md->size = sz;
	md->ptr = data;
	md->addr = *addr;
	worker_push(&md->hdr);
	return;
};

static void report_connect(struct silly_socket *ss, struct socket *s, int err)
{
	(void)ss;
	struct message_connect *mc = mem_alloc(sizeof(*mc));
	mc->hdr.type = MSG_TYPE.connect;
	mc->hdr.unpack = connect_unpack;
	mc->hdr.free = mem_free;
	mc->sid = s->sid;
	mc->err = err;
	worker_push(&mc->hdr);
	return;
}

static inline int add_to_sp(struct silly_socket *ss, struct socket *s)
{
	int ret = sp_add(ss->spfd, s->fd, s);
	if (ret < 0) {
		return ret;
	}
	set_state(s, STATE_POLLING | STATE_READING);
	return 0;
}

static inline void remove_from_sp(struct silly_socket *ss, struct socket *s)
{
	if (!is_polling(s)) {
		return;
	}
	sp_del(ss->spfd, s->fd);
	clr_state(s, STATE_POLLING | STATE_READING | STATE_WRITING);
	closesocket(s->fd);
	s->fd = -1;
}

static inline void free_socket(struct silly_socket *ss, struct socket *s)
{
	assert(s->type != SOCKET_RESERVE);
	wlist_free(s);
	remove_from_sp(ss, s);
	pool_free(&ss->pool, s);
}

static inline void zombine_socket(struct socket *s)
{
	if (is_closing(s)) {
		if (s->type == SOCKET_TCP_CONNECTION) {
			atomic_sub(&SSOCKET->netstat.tcpclient, 1);
		}
		free_socket(SSOCKET, s);
		return;
	}
	wlist_free(s);
	remove_from_sp(SSOCKET, s);
	set_zombine(s);
}

static void nodelay(fd_t fd)
{
	int err;
	int on = 1;
	err = setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, (void *)&on, sizeof(on));
	if (err >= 0)
		return;
	log_error("[socket] nodelay error:%s\n", strerror(errno));
	return;
}

static void keepalive(fd_t fd)
{
	int err;
	int on = 1;
	err = setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, (void *)&on, sizeof(on));
	if (err >= 0)
		return;
	log_error("[socket] keepalive error:%s\n", strerror(errno));
}

static void exec_accept(struct silly_socket *ss, struct socket *listen)
{
	int err, fd;
	struct socket *s;
	union sockaddr_full addr;
	socklen_t len = sizeof(addr);
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
		log_error("[socket] accept reach limit of file descriptor\n");
		ss->reservefd = open("/dev/null", O_RDONLY);
		return;
	}
#ifndef USE_ACCEPT4
	nonblock(fd);
#endif
	keepalive(fd);
	nodelay(fd);
	s = pool_alloc(&ss->pool, fd, SOCKET_TCP_CONNECTION);
	if (unlikely(s == NULL)) {
		log_error("[socket] accept pool_alloc fail\n");
		closesocket(fd);
		return;
	}
	err = add_to_sp(ss, s);
	if (err < 0) {
		free_socket(ss, s);
		return;
	}
	report_accept(ss, listen, s, &addr);
	atomic_add(&ss->netstat.tcpclient, 1);
	return;
}

static inline void rw_enable(struct silly_socket *ss, struct socket *s,
			     int state, int enable)
{
	int flag = 0;
	if (test_state(s, state) == enable)
		return;
	if (enable != 0) {
		set_state(s, state);
	} else {
		clr_state(s, state);
	}
	if (is_reading(s))
		flag |= SP_IN;
	if (is_writing(s))
		flag |= SP_OUT;
	sp_ctrl(ss->spfd, s->fd, s, flag);
}

static inline void write_enable(struct silly_socket *ss, struct socket *s,
				int enable)
{
	rw_enable(ss, s, STATE_WRITING, enable);
}

static inline void read_enable(struct silly_socket *ss, struct socket *s,
			       int enable)
{
	rw_enable(ss, s, STATE_READING, enable);
}

static inline int get_sock_error(struct socket *s)
{
	int ret;
	int err = 0;
	socklen_t len = sizeof(err);
	assert(s->fd > 0);
	ret = getsockopt(s->fd, SOL_SOCKET, SO_ERROR, (void *)&err, &len);
	if (unlikely(ret < 0)) {
		err = errno;
		log_error("[socket] get_sock_error:%s\n", strerror(errno));
	}
	return err;
}

static inline int checkconnected(struct silly_socket *ss, struct socket *s)
{
	int err;
	err = get_sock_error(s);
	if (unlikely(err != 0)) {
		err = translate_socket_errno(err);
		log_error("[socket] checkconnected:%s\n", strerror(err));
		goto err;
	}
	if (wlist_empty(s))
		write_enable(ss, s, 0);
	atomic_add(&ss->netstat.tcpclient, 1);
	report_connect(ss, s, 0);
	return 0;
err:
	//occurs error
	report_connect(ss, s, err);
	free_socket(ss, s);
	return -1;
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

static ssize_t sendudp(fd_t fd, uint8_t *data, size_t sz,
		       const union sockaddr_full *addr)
{
	ssize_t n;
	socklen_t sa_len;
	const struct sockaddr *sa;
	if (addr != NULL) {
		sa = &addr->sa;
		sa_len = sockaddr_len(addr);
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

enum read_result {
	//read some data from socket buffer(the read buffer is not full and not empty)
	READ_SOME = 1,
	//read all data from socket buffer(the read buffer is full)
	READ_ALL = 2,
	//read end of file
	READ_EOF = 3,
	//read error
	READ_ERROR = 4,
};

static enum read_result forward_msg_tcp(struct silly_socket *ss,
					struct socket *s)
{
	if (is_closing(s)) {
		return READ_EOF;
	}
	for (;;) {
		ssize_t len;
		len = recv(s->fd, (void *)ss->readbuf, sizeof(ss->readbuf), 0);
		if (len < 0) {
			switch (errno) {
			case EINTR:
				continue;
			case ETRYAGAIN:
				return READ_ALL;
			default:
				return READ_ERROR;
			}
		} else if (len == 0) {
			return READ_EOF;
		}
		uint8_t *buf = (uint8_t *)mem_alloc(len);
		memcpy(buf, ss->readbuf, len);
		report_tcpdata(ss, s, buf, len);
		atomic_add(&ss->netstat.recvsize, len);
		return len >= (ssize_t)sizeof(ss->readbuf) ? READ_SOME :
							     READ_ALL;
	}
}

static enum read_result forward_msg_udp(struct silly_socket *ss,
					struct socket *s)
{
	uint8_t *data;
	ssize_t n;
	union sockaddr_full addr;
	uint8_t udpbuf[MAX_UDP_PACKET];
	socklen_t len = sizeof(addr);
	if (is_closing(s)) {
		return READ_EOF;
	}
	for (;;) {
		n = recvfrom(s->fd, (void *)udpbuf, MAX_UDP_PACKET, 0,
			     (struct sockaddr *)&addr, &len);
		if (n < 0) {
			switch (errno) {
			case EINTR:
				continue;
			case ETRYAGAIN:
				return READ_ALL;
			default:
				return READ_ERROR;
			}
		}
		data = (uint8_t *)mem_alloc(n);
		memcpy(data, udpbuf, n);
		report_udpdata(ss, s, data, n, &addr);
		atomic_add(&ss->netstat.recvsize, n);
		return READ_SOME;
	}
}

int socket_salen(const void *data)
{
	return sockaddr_len((union sockaddr_full *)data);
}

int socket_ntop(const void *data, char name[SILLY_SOCKET_NAMELEN])
{
	union sockaddr_full *addr;
	addr = (union sockaddr_full *)data;
	return ntop(addr, name);
}

static inline void op_push(struct silly_socket *ss, struct op_hdr *hdr)
{
	if (flipbuf_write(&ss->opbuf, (uint8_t *)hdr, hdr->size)) {
		trigger_fire(&ss->ctrl);
	}
	atomic_fetch_add_explicit(&ss->netstat.oprequest, 1,
				  memory_order_relaxed);
}

void socket_read_enable(socket_id_t sid, int flag)
{
	struct socket *s;
	struct op_readenable op = { 0 };
	s = pool_get(&SSOCKET->pool, sid);
	if (unlikely(s == NULL || is_zombine(s)))
		return;
	op.hdr.op = OP_READ_ENABLE;
	op.hdr.sid = sid;
	op.hdr.size = sizeof(op);
	op.ctrl = flag;
	op_push(SSOCKET, &op.hdr);
	return;
}

static void op_read_enable(struct silly_socket *ss, struct op_readenable *op,
			   struct socket *s)
{
	int enable = op->ctrl;
	read_enable(ss, s, enable);
}

int socket_send_size(socket_id_t sid)
{
	struct socket *s;
	s = pool_get(&SSOCKET->pool, sid);
	if (unlikely(s == NULL))
		return 0;
	return atomic_load_explicit(&s->wlbytes, memory_order_relaxed);
}

static int send_msg_tcp(struct silly_socket *ss, struct socket *s)
{
	struct wlist *w = s->wlhead;
	while (w) {
		ssize_t sz;
		assert(w->size > s->wloffset);
		sz = sendn(s->fd, w->buf + s->wloffset, w->size - s->wloffset);
		if (unlikely(sz < 0)) {
			return -1;
		}
		s->wloffset += sz;
		atomic_fetch_sub_explicit(&s->wlbytes, sz,
					  memory_order_relaxed);
		if (s->wloffset < w->size) //send some
			break;
		assert((size_t)s->wloffset == w->size);
		s->wloffset = 0;
		s->wlhead = w->next;
		w->free(w->buf);
		mem_free(w);
		w = s->wlhead;
		if (w == NULL) { //send ok
			s->wltail = &s->wlhead;
			write_enable(ss, s, 0);
			if (is_closing(s)) {
				atomic_sub(&ss->netstat.tcpclient, 1);
				free_socket(ss, s);
				return 0;
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
		if (sz > 0) {
			atomic_fetch_sub_explicit(&s->wlbytes, sz,
						  memory_order_relaxed);
		}
		//send fail && send ok will clear
		s->wlhead = w->next;
		w->free(w->buf);
		mem_free(w);
		w = s->wlhead;
		if (w == NULL) { //send all
			s->wltail = &s->wlhead;
			write_enable(ss, s, 0);
			if (is_closing(s)) {
				free_socket(ss, s);
				return 0;
			}
		}
	}
	return 0;
}

static inline struct addrinfo *getsockaddr(int protocol, const char *ip,
					   const char *port, int *errp)
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
		*errp = -EX_ADDRINFO;
		log_error("[socket] bindfd ip:%s port:%s err:%s\n", ip, port,
			  gai_strerror(err));
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
	info = getsockaddr(protocol, ip, port, &err);
	if (info == NULL)
		return err;
	err = bind(fd, info->ai_addr, info->ai_addrlen);
	if (err < 0) {
		err = -errno;
		log_error("[socket] bindfd ip:%s port:%s err:%s\n", ip, port,
			  strerror(errno));
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
	info = getsockaddr(IPPROTO_TCP, ip, port, &err);
	if (unlikely(info == NULL))
		return err;
	fd = socket(info->ai_family, SOCK_STREAM, 0);
	if (unlikely(fd < 0)) {
		err = -errno;
		goto end;
	}
	setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, (void *)&reuse, sizeof(reuse));
	err = bind(fd, info->ai_addr, info->ai_addrlen);
	if (unlikely(err < 0)) {
		err = -errno;
		goto end;
	}
	nonblock(fd);
	err = listen(fd, backlog);
	if (unlikely(err < 0)) {
		err = -errno;
		goto end;
	}
	freeaddrinfo(info);
	return fd;
end:
	freeaddrinfo(info);
	if (fd >= 0)
		closesocket(fd);
	log_error("[socket] dolisten error:%s\n", strerror(errno));
	return err;
}

socket_id_t socket_tcp_listen(const char *ip, const char *port, int backlog)
{
	fd_t fd;
	struct socket *s;
	struct op_listen op = { 0 };
	fd = dolisten(ip, port, backlog);
	if (unlikely(fd < 0))
		return fd;
	s = pool_alloc(&SSOCKET->pool, fd, SOCKET_TCP_LISTEN);
	if (unlikely(s == NULL)) {
		log_error("[socket] listen %s:%s:%d pool_alloc fail\n", ip,
			  port, backlog);
		closesocket(fd);
		return -EX_NOSOCKET;
	}
	set_listening(s);
	op.hdr.op = OP_TCP_LISTEN;
	op.hdr.sid = s->sid;
	op.hdr.size = sizeof(op);
	op_push(SSOCKET, &op.hdr);
	return s->sid;
}

static int op_tcp_listen(struct silly_socket *ss, struct op_listen *op,
			 struct socket *s)
{
	int err;
	(void)op;
	assert(is_listening(s) && s->type == SOCKET_TCP_LISTEN);
	err = add_to_sp(ss, s);
	if (unlikely(err < 0)) {
		log_error("[socket] trylisten error:%s\n", strerror(errno));
		report_listen(ss, s, errno);
		closesocket(s->fd);
		free_socket(ss, s);
		return err;
	}
	clr_listening(s);
	report_listen(ss, s, 0);
	return err;
}

socket_id_t socket_udp_bind(const char *ip, const char *port)
{
	int err;
	fd_t fd = -1;
	struct op_listen op = { 0 };
	struct addrinfo *info;
	struct socket *s = NULL;
	info = getsockaddr(IPPROTO_UDP, ip, port, &err);
	if (info == NULL)
		return err;
	fd = socket(info->ai_family, SOCK_DGRAM, 0);
	if (unlikely(fd < 0)) {
		err = -errno;
		goto end;
	}
	err = bind(fd, info->ai_addr, info->ai_addrlen);
	if (unlikely(err < 0)) {
		err = -errno;
		goto end;
	}
	nonblock(fd);
	s = pool_alloc(&SSOCKET->pool, fd, SOCKET_UDP_LISTEN);
	if (unlikely(s == NULL)) {
		log_error("[socket] udpbind %s:%s pool_alloc fail\n", ip, port);
		err = -EX_NOSOCKET;
		goto end;
	}
	freeaddrinfo(info);
	set_listening(s);
	op.hdr.op = OP_UDP_LISTEN;
	op.hdr.sid = s->sid;
	op.hdr.size = sizeof(op);
	op_push(SSOCKET, &op.hdr);
	return s->sid;
end:
	if (fd >= 0)
		closesocket(fd);
	freeaddrinfo(info);
	log_error("[socket] udplisten error:%s\n", strerror(errno));
	return err;
}

static int op_udp_listen(struct silly_socket *ss, struct op_listen *op,
			 struct socket *s)
{
	int err;
	(void)op;
	assert(is_listening(s) && s->type == SOCKET_UDP_LISTEN);
	err = add_to_sp(ss, s);
	if (unlikely(err < 0)) {
		log_error("[socket] tryudpbind error:%s\n", strerror(errno));
		report_listen(ss, s, errno);
		closesocket(s->fd);
		free_socket(ss, s);
		return err;
	}
	clr_listening(s);
	report_listen(ss, s, 0);
	return err;
}

socket_id_t socket_tcp_connect(const char *ip, const char *port,
			       const char *bindip, const char *bindport)
{
	int err, fd = -1;
	struct op_connect op = { 0 };
	struct addrinfo *info;
	struct socket *s = NULL;
	assert(ip);
	assert(bindip);
	info = getsockaddr(IPPROTO_TCP, ip, port, &err);
	if (unlikely(info == NULL))
		return err;
	fd = socket(info->ai_family, SOCK_STREAM, 0);
	if (unlikely(fd < 0)) {
		err = -errno;
		goto end;
	}
	err = bindfd(fd, IPPROTO_TCP, bindip, bindport);
	if (unlikely(err < 0))
		goto end;
	s = pool_alloc(&SSOCKET->pool, fd, SOCKET_TCP_CONNECTION);
	if (unlikely(s == NULL)) {
		err = -EX_NOSOCKET;
		goto end;
	}
	set_connecting(s);
	op.hdr.op = OP_TCP_CONNECT;
	op.hdr.sid = s->sid;
	op.hdr.size = sizeof(op);
	assert(sizeof(op.addr) >= info->ai_addrlen);
	memcpy(&op.addr, info->ai_addr, info->ai_addrlen);
	op_push(SSOCKET, &op.hdr);
	freeaddrinfo(info);
	return s->sid;
end:
	if (fd >= 0)
		closesocket(fd);
	freeaddrinfo(info);
	return err;
}

static void op_tcp_connect(struct silly_socket *ss, struct op_connect *op,
			   struct socket *s)
{
	fd_t fd;
	int cret, sret;
	union sockaddr_full *addr;
	assert(s->fd >= 0);
	assert(is_connecting(s) && s->type == SOCKET_TCP_CONNECTION);
	fd = s->fd;
	nonblock(fd);
	keepalive(fd);
	nodelay(fd);
	addr = &op->addr;
	cret = connect(fd, &addr->sa, sockaddr_len(addr));
	if (unlikely(cret == -1 && errno != CONNECT_IN_PROGRESS)) { //error
		char namebuf[SILLY_SOCKET_NAMELEN];
		const char *fmt = "[socket] connect %s,errno:%d\n";
		report_connect(ss, s, errno);
		free_socket(ss, s);
		ntop(addr, namebuf);
		log_error(fmt, namebuf, errno);
		return;
	}
	sret = add_to_sp(ss, s);
	if (unlikely(sret < 0)) {
		report_connect(ss, s, errno);
		free_socket(ss, s);
		return;
	}
	if (cret == 0) { //connect
		clr_connecting(s);
		atomic_add(&ss->netstat.tcpclient, 1);
		report_connect(ss, s, 0);
		if (!wlist_empty(s))
			write_enable(ss, s, 1);
	} else { //block
		set_connecting(s);
		write_enable(ss, s, 1);
		atomic_add(&ss->netstat.connecting, 1);
	}
}

socket_id_t socket_udp_connect(const char *ip, const char *port,
			       const char *bindip, const char *bindport)
{
	int err;
	fd_t fd = -1;
	struct op_connect op = { 0 };
	struct addrinfo *info;
	struct socket *s = NULL;
	const char *fmt = "[socket] udpconnect %s:%d, errno:%d\n";
	assert(ip);
	assert(bindip);
	info = getsockaddr(IPPROTO_UDP, ip, port, &err);
	if (unlikely(info == NULL))
		return err;
	fd = socket(info->ai_family, SOCK_DGRAM, 0);
	if (unlikely(fd < 0)) {
		err = -errno;
		goto end;
	}
	err = bindfd(fd, IPPROTO_UDP, bindip, bindport);
	if (unlikely(err < 0))
		goto end;
	//udp connect will return immediately
	err = connect(fd, info->ai_addr, info->ai_addrlen);
	if (unlikely(err < 0)) {
		err = -errno;
		goto end;
	}
	s = pool_alloc(&SSOCKET->pool, fd, SOCKET_UDP_CONNECTION);
	if (unlikely(s == NULL)) {
		err = -EX_NOSOCKET;
		goto end;
	}
	set_connecting(s);
	op.hdr.op = OP_UDP_CONNECT;
	op.hdr.sid = s->sid;
	op.hdr.size = sizeof(op);
	op_push(SSOCKET, &op.hdr);
	freeaddrinfo(info);
	return s->sid;
end:
	if (fd >= 0)
		closesocket(fd);
	freeaddrinfo(info);
	log_error(fmt, ip, port, errno);
	return err;
}

static void op_udp_connect(struct silly_socket *ss, struct op_connect *op,
			   struct socket *s)
{
	int err;
	(void)op;
	assert(s->fd >= 0);
	assert(is_connecting(s) && s->type == SOCKET_UDP_CONNECTION);
	clr_connecting(s);
	err = add_to_sp(ss, s);
	if (unlikely(err < 0)) {
		report_connect(ss, s, errno);
		free_socket(ss, s);
		return;
	}
	report_connect(ss, s, 0);
	return;
}

int socket_close(socket_id_t sid)
{
	struct op_close op = { 0 };
	struct socket *s = pool_get(&SSOCKET->pool, sid);
	if (unlikely(s == NULL)) {
		log_warn("[socket] socket_close already closed sid:%llu\n",
			 sid);
		return -EX_CLOSED;
	}
	if (is_closing(s)) {
		log_warn("[socket] socket_close already closing sid:%llu\n",
			 sid);
		return -EX_CLOSING;
	}
	if (is_zombine(s)) {
		if (s->type == SOCKET_TCP_CONNECTION) {
			atomic_sub(&SSOCKET->netstat.tcpclient, 1);
		}
		free_socket(SSOCKET, s);
		return 0;
	}
	set_state(s, STATE_CLOSING | STATE_MUTECLOSE);
	op.hdr.op = OP_CLOSE;
	op.hdr.sid = sid;
	op.hdr.size = sizeof(op);
	op_push(SSOCKET, &op.hdr);
	return 0;
}

static int op_tcp_close(struct silly_socket *ss, struct op_close *op,
			struct socket *s)
{
	int type;
	(void)op;
	type = s->type;
	if (unlikely(type == SOCKET_PIPE_CTRL || type == SOCKET_RESERVE)) {
		log_error("[socket] op_tcp_close unsupport type %d\n", type);
		return -1;
	}
	if (wlist_empty(s)) { //already send all the data, directly close it
		if (s->type == SOCKET_TCP_CONNECTION) {
			atomic_sub(&SSOCKET->netstat.tcpclient, 1);
		}
		free_socket(ss, s);
		return 0;
	} else {
		read_enable(ss, s, 0);
		return -1;
	}
}

int socket_tcp_send(socket_id_t sid, uint8_t *buf, size_t sz,
		    void (*freex)(void *))
{
	struct op_tcpsend op = { 0 };
	struct socket *s = pool_get(&SSOCKET->pool, sid);
	if (freex == NULL)
		freex = mem_free;
	if (unlikely(s == NULL || is_zombine(s))) {
		freex(buf);
		log_error("[socket] socket_tcp_send sid:%llu closed\n", sid);
		return -EX_CLOSED;
	}
	if (unlikely(sz == 0)) {
		freex(buf);
		log_warn("[socket] socket_tcp_send empty data sid:%llu\n", sid);
		return 0;
	}
	op.hdr.op = OP_TCP_SEND;
	op.hdr.sid = sid;
	op.hdr.size = sizeof(op);
	op.data = buf;
	op.size = sz;
	op.free = freex;
	atomic_add(&s->wlbytes, sz);
	op_push(SSOCKET, &op.hdr);
	return 0;
}

static void op_tcp_send(struct silly_socket *ss, struct op_tcpsend *op,
			struct socket *s)
{
	uint8_t *data = op->data;
	size_t sz = op->size;
	void (*freex)(void *) = op->free;
	if (unlikely(s->type != SOCKET_TCP_CONNECTION)) {
		freex(data);
		atomic_sub(&s->wlbytes, sz);
		log_error("[socket] op_tcp_send incorrect socket "
			  "sid:%llu type:%d zombie:%d\n",
			  s->sid, s->type, is_zombine(s));
		return;
	}
	atomic_add(&ss->netstat.sendsize, sz);
	if (wlist_empty(s) && !is_connecting(s)) { //try send
		ssize_t n = sendn(s->fd, data, sz);
		if (n < 0) {
			freex(data);
			atomic_sub(&s->wlbytes, sz);
			report_close(ss, s, errno);
			zombine_socket(s);
		} else if ((size_t)n < sz) {
			s->wloffset = n;
			wlist_append(s, data, sz, freex);
			write_enable(ss, s, 1);
			atomic_sub(&s->wlbytes, n);
		} else {
			assert((size_t)n == sz);
			freex(data);
			atomic_sub(&s->wlbytes, sz);
		}
	} else {
		assert(test_state(s, STATE_WRITING | STATE_READING));
		wlist_append(s, data, sz, freex);
	}
}

int socket_udp_send(socket_id_t sid, uint8_t *buf, size_t sz,
		    const uint8_t *addr, size_t addrlen, void (*freex)(void *))
{
	struct op_udpsend op = { 0 };
	struct socket *s = pool_get(&SSOCKET->pool, sid);
	freex = freex ? freex : mem_free;
	if (unlikely(s == NULL || is_zombine(s))) {
		freex(buf);
		log_error("[socket] socket_udp_send invalid sid:%llu\n", sid);
		return -EX_CLOSED;
	}
	op.hdr.op = OP_UDP_SEND;
	op.hdr.sid = sid;
	op.hdr.size = sizeof(op);
	op.data = buf;
	op.size = sz;
	op.free = freex;
	if (addrlen > 0) {
		assert(addrlen <= sizeof(op.addr));
		memcpy(&op.addr, addr, addrlen);
	}
	atomic_add(&s->wlbytes, sz);
	op_push(SSOCKET, &op.hdr);
	return 0;
}

static int op_udp_send(struct silly_socket *ss, struct op_udpsend *op,
		       struct socket *s)
{
	size_t size;
	uint8_t *data;
	union sockaddr_full *addr;
	data = op->data;
	void (*freex)(void *) = op->free;
	if (unlikely(socket_protocol(s) != PROTOCOL_UDP)) {
		freex(data);
		atomic_sub(&s->wlbytes, op->size);
		log_error("[socket] op_udp_send incorrect socket "
			  "sid:%llu type:%d zombie:%d\n",
			  s->sid, s->type, is_zombine(s));
		return 0;
	}
	size = op->size;
	atomic_add(&ss->netstat.sendsize, size);
	if (s->type == SOCKET_UDP_LISTEN) {
		//only udp server need address
		addr = &op->addr;
	} else {
		addr = NULL;
	}
	if (wlist_empty(s)) { //try send
		ssize_t n = sendudp(s->fd, data, size, addr);
		if (n == -1 || n >= 0) { //occurs error or send ok
			freex(data);
			atomic_sub(&s->wlbytes, size);
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

void socket_terminate()
{
	struct op_exit op = { 0 };
	op.hdr.op = OP_EXIT;
	op.hdr.sid = 0;
	op.hdr.size = sizeof(op);
	op_push(SSOCKET, &op.hdr);
	return;
}

static int op_process(struct silly_socket *ss)
{
	struct array *arr;
	uint8_t *ptr, *end;
	if (trigger_consume(&ss->ctrl) <= 0) // no more op to process
		return 0;
	arr = flipbuf_flip(&ss->opbuf);
	ptr = (uint8_t *)arr->buf;
	end = ptr + arr->size;
	while (ptr < end) {
		struct socket *s;
		struct op_pkt *op = (struct op_pkt *)ptr;
		atomic_fetch_add_explicit(&ss->netstat.opprocessed, 1,
					  memory_order_relaxed);
		if (op->hdr.op == OP_EXIT)
			return -1;
		assert(op->hdr.size > 0);
		ptr += op->hdr.size;
		s = pool_get(&ss->pool, op->hdr.sid);
		if (s == NULL || (op->hdr.op != OP_CLOSE && is_zombine(s))) {
			if (op->hdr.op == OP_TCP_SEND) {
				op->tcpsend.free(op->tcpsend.data);
			} else if (op->hdr.op == OP_UDP_SEND) {
				op->udpsend.free(op->udpsend.data);
			}
			log_warn(
				"[socket] op_process op:%d sid:%llu zombie:%d\n",
				op->hdr.op, op->hdr.sid, s && is_zombine(s));
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
			op_tcp_close(ss, &op->close, s);
			break;
		case OP_TCP_SEND:
			op_tcp_send(ss, &op->tcpsend, s);
			break;
		case OP_UDP_SEND:
			//udp socket can only be closed active
			op_udp_send(ss, &op->udpsend, s);
			break;
		case OP_READ_ENABLE:
			op_read_enable(ss, &op->readenable, s);
			break;
		default:
			log_error("[socket] op_process:"
				  "unkonw operation:%d\n",
				  op->hdr.op);
			assert(!"oh, no!");
			break;
		}
	}
	return 0;
}

static void eventwait(struct silly_socket *ss)
{
	for (;;) {
		ss->eventcount = sp_wait(ss->spfd, ss->eventbuf, ss->eventcap);
		ss->eventindex = 0;
		if (ss->eventcount < 0) {
			log_error("[socket] eventwait:%d\n", errno);
			continue;
		}
		break;
	}
	return;
}

static void parse_read_error(enum read_result ret, int *eof, int *has_error,
			     int *has_data_to_read)
{
	switch (ret) {
	case READ_EOF:
		*eof = 1;
		break;
	case READ_ERROR:
		*has_error = errno;
		break;
	case READ_SOME:
		*has_data_to_read = 1;
		break;
	case READ_ALL:
		break;
	default:
		assert(!"oh, no!");
		break;
	}
}

int socket_poll()
{
	int err;
	event_t *e;
	struct socket *s;
	struct silly_socket *ss = SSOCKET;
	eventwait(ss);
	err = op_process(ss);
	if (err < 0)
		return -1;
	while (ss->eventindex < ss->eventcount) {
		int eof = 0;
		int err = 0;
		int has_data_to_read = 0;
		int ei = ss->eventindex++;
		e = &ss->eventbuf[ei];
		s = (struct socket *)SP_UD(e);
		if (s == NULL)
			continue;
		if (is_zombine(s) || sid(s) < 0)
			continue;
		switch (s->type) {
		case SOCKET_TCP_LISTEN:
			assert(SP_READ(e));
			exec_accept(ss, s);
			break;
		case SOCKET_TCP_CONNECTION:
			if (is_connecting(s)) {
				clr_connecting(s);
				atomic_sub(&ss->netstat.connecting, 1);
				checkconnected(ss, s);
				continue;
			}
			if (SP_READ(e)) {
				int ret = forward_msg_tcp(ss, s);
				parse_read_error(ret, &eof, &err,
						 &has_data_to_read);
			}
			if (SP_WRITE(e)) {
				if (send_msg_tcp(ss, s) < 0) {
					err = errno;
				}
			}
			if (has_data_to_read) // if has data to read, delay the error process to next wait
				continue;
			if (err == 0 && SP_ERR(e)) {
				err = get_sock_error(s);
			}
			if (err != 0) {
				report_close(ss, s, err);
				zombine_socket(s);
			} else if (eof || SP_EOF(e)) {
				report_close(ss, s, EX_EOF);
				read_enable(ss, s, 0);
			}
			break;
		case SOCKET_UDP_LISTEN:
		case SOCKET_UDP_CONNECTION:
			if (SP_READ(e)) {
				forward_msg_udp(ss, s);
			}
			if (SP_WRITE(e)) {
				send_msg_udp(ss, s);
			}
			if (SP_ERR(e)) {
				report_close(ss, s, get_sock_error(s));
				zombine_socket(s);
			}
			break;
		case SOCKET_PIPE_CTRL:
			break;
		default:
			log_error("[socket] poll: unkonw socket type:%d\n",
				  s->type);
			break;
		}
	}
	return 0;
}

static void resize_eventbuf(struct silly_socket *ss, size_t sz)
{
	ss->eventcap = sz;
	ss->eventbuf =
		(event_t *)mem_realloc(ss->eventbuf, sizeof(event_t) * sz);
	return;
}

const struct silly_socket_msgtype *socket_msg_types()
{
	assert(MSG_TYPE.accept != 0); // ensure socket_init has been called
	return &MSG_TYPE;
}

int socket_init()
{
	int err;
	fd_t spfd = SP_INVALID;
	struct socket *s = NULL;
	struct silly_socket *ss;
	spfd = sp_create(EVENT_SIZE);
	if (unlikely(spfd == SP_INVALID))
		return -errno;
	ss = mem_alloc(sizeof(*ss));
	memset(ss, 0, sizeof(*ss));
	pool_init(&ss->pool);
	flipbuf_init(&ss->opbuf);
	err = trigger_init(&ss->ctrl);
	if (unlikely(err < 0))
		goto end;
	ss->spfd = spfd;
	ss->reservefd = open("/dev/null", O_RDONLY);
	s = pool_alloc(&ss->pool, trigger_fd(&ss->ctrl), SOCKET_PIPE_CTRL);
	err = add_to_sp(ss, s);
	if (unlikely(err < 0))
		goto end;
	atomic_init(&ss->netstat.connecting, 0);
	atomic_init(&ss->netstat.tcpclient, 0);
	atomic_init(&ss->netstat.recvsize, 0);
	atomic_init(&ss->netstat.sendsize, 0);
	atomic_init(&ss->netstat.oprequest, 0);
	atomic_init(&ss->netstat.opprocessed, 0);
	ss->eventindex = 0;
	ss->eventcount = 0;
	resize_eventbuf(ss, EVENT_SIZE);
	SSOCKET = ss;
	MSG_TYPE.accept = message_new_type();
	MSG_TYPE.connect = message_new_type();
	MSG_TYPE.listen = message_new_type();
	MSG_TYPE.tcpdata = message_new_type();
	MSG_TYPE.udpdata = message_new_type();
	MSG_TYPE.close = message_new_type();
	return 0;
end:
	if (s != NULL)
		free_socket(ss, s);
	if (spfd != SP_INVALID) {
		sp_free(spfd);
	}
	if (ss != NULL) {
		trigger_destroy(&ss->ctrl);
		flipbuf_destroy(&ss->opbuf);
		mem_free(ss);
	}

	return -errno;
}

void socket_exit()
{
	int i;
	assert(SSOCKET);
	sp_free(SSOCKET->spfd);
	closesocket(SSOCKET->reservefd);
	trigger_destroy(&SSOCKET->ctrl);
	struct socket *s = &SSOCKET->pool.slots[0];
	for (i = 0; i < SOCKET_POOL_SIZE; i++) {
		int type = socket_type(s);
		if (type == SOCKET_CONNECTION || type == SOCKET_LISTEN) {
			closesocket(s->fd);
		}
		++s;
	}
	flipbuf_destroy(&SSOCKET->opbuf);
	mem_free(SSOCKET->eventbuf);
	mem_free(SSOCKET);
	return;
}

const char *socket_pollapi()
{
	return SOCKET_POLL_API;
}

void socket_netstat(struct silly_netstat *stat)
{
	stat->connecting = atomic_load_explicit(&SSOCKET->netstat.connecting,
						memory_order_relaxed);
	stat->tcpclient = atomic_load_explicit(&SSOCKET->netstat.tcpclient,
					       memory_order_relaxed);
	stat->recvsize = atomic_load_explicit(&SSOCKET->netstat.recvsize,
					      memory_order_relaxed);
	stat->sendsize = atomic_load_explicit(&SSOCKET->netstat.sendsize,
					      memory_order_relaxed);
	stat->oprequest = atomic_load_explicit(&SSOCKET->netstat.oprequest,
					       memory_order_relaxed);
	stat->opprocessed = atomic_load_explicit(&SSOCKET->netstat.opprocessed,
						 memory_order_relaxed);
	return;
}

void socket_stat(socket_id_t sid, struct silly_socketstat *info)
{
	struct socket *s;
	memset(info, 0, sizeof(*info));
	s = pool_get(&SSOCKET->pool, sid);
	if (s == NULL) {
		log_error("[socket] socket_stat sid:%llu invalid\n", sid);
		return;
	}
	int fd = s->fd;
	int protocol = socket_protocol(s);
	int type = socket_type(s);
	s = pool_get(&SSOCKET->pool, sid);
	if (s == NULL || is_zombine(s)) {
		log_error("[socket] socket_stat sid:%llu invalid\n", sid);
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
		char namebuf[SILLY_SOCKET_NAMELEN];
		len = sizeof(addr);
		getsockname(info->fd, (struct sockaddr *)&addr, &len);
		namelen = ntop(&addr, namebuf);
		memcpy(info->localaddr, namebuf, namelen);
		if (type == SOCKET_TCP_CONNECTION) {
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
