#include "silly.h"
#include <assert.h>
#include <stdio.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>

#include "atomic.h"
#include "compiler.h"
#include "cmdbuf.h"
#include "net.h"
#include "event.h"
#include "nonblock.h"
#include "spinlock.h"
#include "socket.h"
#include "silly_log.h"
#include "silly_worker.h"
#include "silly_malloc.h"
#include "silly_socket.h"

//STYPE == socket type

#define EVENT_SIZE (128)
#define CMDBUF_SIZE (8 * sizeof(struct cmdpacket))


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

struct socketpool {
	struct socket sockets[MAX_SOCKET_COUNT];
	struct socket *free_for_alloc;
	struct socket *free_for_release;
	struct socket **next_for_release;
	spinlock_t lock;
};

struct silly_socket {
	//event
	struct event *ev;
	// socket pool
	struct socketpool pool;
	// cmd queue
	struct cmdbuf cmdbuf;
	//netstat
	struct silly_netstat netstat;
	//error message
	char errmsg[256];
};

//for read one complete packet once system call, fix the packet length
#define cmdcommon int type;\
	int64_t sid

struct cmdlisten { //'L/B' -> listen or bind
	cmdcommon;
};

struct cmdconnect { //'C' -> tcp connect
	cmdcommon;
	union sockaddr_full addr;
};

struct cmdopen { //'O' -> udp connect
	cmdcommon;
};

struct cmdkick { //'K' --> close
	cmdcommon;
};

struct cmdsend { //'S' --> tcp send
	cmdcommon;
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
	int ctrl;
};

struct cmdterm {
	cmdcommon;
};

struct cmdpacket {
	union {
		struct {
			cmdcommon;
		};
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

static inline void socketpool_init(struct socketpool *pool)
{
	int i;
	struct socket **next;
	spinlock_init(&pool->lock);
	pool->free_for_alloc = NULL;
	pool->free_for_release = NULL;
	pool->next_for_release = &pool->free_for_release;
	next = &pool->free_for_alloc;
	// the first one is invalid
	for (i = 0; i < MAX_SOCKET_COUNT; i++) {
		struct socket *s = &pool->sockets[i];
		s->sid = 0;
		s->fd = -1;
		s->version = 0;
		s->type = STYPE_FREE;
		s->next = NULL;
		s->wloffset = 0;
		s->wlhead = NULL;
		s->wltail = &s->wlhead;
		memset(&s->sendmsg, 0, sizeof(s->sendmsg));
		mvec_init(&s->sendmsg.vecs[0]);
		mvec_init(&s->sendmsg.vecs[1]);
		if (i > 0) { // the first one is invalid
			*next = s;
			next = &s->next;
		}
	}
}

static inline void socketpool_destroy(struct socketpool *pool)
{
	(void)pool;
	for (int i = 0; i < MAX_SOCKET_COUNT; i++) {
		struct socket *s = &pool->sockets[i];
		if (s->fd >= 0) {
			closesocket(s->fd);
			s->fd = -1;
		}
		wlist_free(s);
		//TODO: 链接关闭时，相办法回收这块内存，防止内存泄漏
		iomsg_free(&s->sendmsg);
	}
}

static inline struct socket *socketpool_get(struct socketpool *pool, int64_t sid)
{
	struct socket *s;
	s = &pool->sockets[sid & (MAX_SOCKET_COUNT - 1)];
	if (likely(s->sid == sid)) {
		return s;
	}
	return &pool->sockets[0];
}

static struct socket *socketpool_alloc(struct socketpool *pool,
	fd_t fd, enum stype type, unsigned char protocol)
{
	struct socket *s;
	spinlock_lock(&pool->lock);
	s = pool->free_for_alloc;
	if (s == NULL) {
		pool->free_for_alloc = pool->free_for_release;
		pool->free_for_release = NULL;
		pool->next_for_release = &pool->free_for_release;
		s = pool->free_for_alloc;
	}
	if (s != NULL) {
		pool->free_for_alloc = s->next;
	}
	spinlock_unlock(&pool->lock);
	if (s == NULL) {
		return NULL;
	}
	s->sid = ((uint64_t)(s->version) << SOCKET_MAX_EXP) | (s - &pool->sockets[0]);
	s->fd = fd;
	s->type = type;
	s->protocol = protocol;
	s->wloffset = 0;
	s->next = NULL;
	s->flags = 0;
	return s;
}

static inline void socketpool_release(struct socketpool *pool, struct socket *s)
{
	(void)pool;
	wlist_free(s);
	assert(s->wlhead == NULL);
	s->sid = 0;
	s->type = STYPE_FREE;
	s->fd = -1;
	s->version++;
	assert(s->next == NULL);
	spinlock_lock(&pool->lock);
	*pool->next_for_release = s;
	pool->next_for_release = &s->next;
	spinlock_unlock(&pool->lock);
}


static inline void reset_errmsg(struct silly_socket *ss)
{
	ss->errmsg[0] = '\0';
}

static inline void set_errmsg(struct silly_socket *ss, const char *str)
{
	snprintf(ss->errmsg, sizeof(ss->errmsg), "%s", str);
}

static inline struct socket *allocsocket(struct silly_socket *ss, fd_t fd,
					enum stype type, unsigned char protocol)
{
	struct socket *s;
	s = socketpool_alloc(&ss->pool, fd, type, protocol);
	if (unlikely(s == NULL)) {
		set_errmsg(ss, "socket pool is full");
		silly_log_error("[socket] allocsocket fail, find no empty entry\n");
	}
	return s;
}

static inline void netstat_close(struct silly_socket *ss, struct socket *s)
{
	if (s->protocol != PROTOCOL_TCP ||
	    (s->type != STYPE_SOCKET && !is_close_local(s))) {
		return;
	}
	ss->netstat.tcpclient--;
};

static inline void freesocket(struct silly_socket *ss, struct socket *s)
{
	printf("******* closing socket sid:%llu type:%d\n",
		s->sid, s->type);
	if (unlikely(s->type == STYPE_FREE)) {
		const char *fmt = "[socket] freesocket sid:%llu error type:%d\n";
		silly_log_error(fmt, s->sid, s->type);
		return;
	}
	if (s->fd >= 0) {
		closesocket(s->fd);
		s->fd = -1;
	}
	netstat_close(ss, s);
	socketpool_release(&ss->pool, s);
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

static void cmdbuf_write(struct silly_socket *ss, void *dat, int size)
{
	if (cmdbuf_append(&ss->cmdbuf, dat, size))
		event_wakeup(ss->ev);
}

static struct array *cmdbuf_read(struct silly_socket *ss)
{
	return cmdbuf_flip(&ss->cmdbuf);
}

static void report_accept(struct silly_socket *ss, struct xevent *e)
{
	int err;
	char namebuf[SOCKET_NAMELEN];
	struct socket *s = allocsocket(ss, e->fd, STYPE_SOCKET, PROTOCOL_TCP);
	if (unlikely(s == NULL)) {
		closesocket(e->fd);
		return;
	}
	err = event_add(ss->ev, s);
	if (err < 0) {
		freesocket(ss, s);
		return;
	}
#ifdef SILLY_TEST
	// set sendbuf/recvbuf to 1k for test
	int size = 1024;
	setsockopt(e->fd, SOL_SOCKET, SO_SNDBUF, &size, sizeof(size));
	setsockopt(e->fd, SOL_SOCKET, SO_RCVBUF, &size, sizeof(size));
#endif
	int namelen = ntop(&e->addr, namebuf);
	silly_message_accept(s->sid, e->s->sid, namebuf, namelen);
	ss->netstat.tcpclient++;
	return;
}

static void report_close(struct silly_socket *ss, struct socket *s, int err)
{
	(void)ss;
	int type;
	if (is_close_local(s)) //don't notify the active close
		return;
	type = s->type;
	assert(type == STYPE_LISTEN || type == STYPE_SOCKET ||
	       type == STYPE_ALLOC);
	silly_message_close(s->sid, err);
	return;
}

static void report_data(struct silly_socket *ss, struct socket *s, int type,
			uint8_t *data, size_t sz)
{
	(void)ss;
	assert(s->type == STYPE_SOCKET || s->type == STYPE_UDPBIND);
	assert(type == SILLY_SDATA || type == SILLY_SUDP);
	silly_message_data(s->sid, type, data, sz);
	return;
};

static void report_connected(struct silly_socket *ss, struct socket *s)
{
	ss->netstat.tcpclient++;
	silly_message_connected(s->sid);
	return;
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

void silly_socket_readctrl(int64_t sid, int flag)
{
	struct socket *s;
	struct cmdreadctrl cmd;
	s = socketpool_get(&SSOCKET->pool, sid);
	if (s->type != STYPE_SOCKET)
		return;
	cmd.type = 'R';
	cmd.sid = sid;
	cmd.ctrl = flag;
	cmdbuf_write(SSOCKET, &cmd, sizeof(cmd));
	return;
}

int silly_socket_sendsize(int64_t sid)
{
	int size = 0;
	struct wlist *w;
	struct socket *s;
	s = socketpool_get(&SSOCKET->pool, sid);
	if (s->type != STYPE_SOCKET)
		return size;
	for (w = s->wlhead; w != NULL; w = w->next)
		size += w->size;
	size -= s->wloffset;
	return size;
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

int64_t silly_socket_listen(const char *ip, const char *port, int backlog)
{
	fd_t fd;
	struct socket *s;
	struct cmdlisten cmd;
	reset_errmsg(SSOCKET);
	fd = dolisten(ip, port, backlog);
	if (unlikely(fd < 0))
		return -errno;
	s = allocsocket(SSOCKET, fd, STYPE_ALLOC, PROTOCOL_TCP);
	if (unlikely(s == NULL)) {
		silly_log_error("[socket] listen %s:%s:%d allocsocket fail\n",
				ip, port, backlog);
		closesocket(fd);
		return -1;
	}
	cmd.type = 'L';
	cmd.sid = s->sid;
	cmdbuf_write(SSOCKET, &cmd, sizeof(cmd));
	return s->sid;
}

int64_t silly_socket_udpbind(const char *ip, const char *port)
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
	s = allocsocket(SSOCKET, fd, STYPE_ALLOC, PROTOCOL_UDP);
	if (unlikely(s == NULL)) {
		silly_log_error("[socket] udpbind %s:%s allocsocket fail\n", ip,
				port);
		goto end;
	}
	freeaddrinfo(info);
	cmd.type = 'B';
	cmd.sid = s->sid;
	cmdbuf_write(SSOCKET, &cmd, sizeof(cmd));
	return s->sid;
end:
	if (fd >= 0)
		closesocket(fd);
	freeaddrinfo(info);
	silly_log_error("[socket] udplisten error:%s\n", strerror(errno));
	return -1;
}

static int trylisten(struct silly_socket *ss, struct socket *s)
{
	int err;
	assert(s->type == STYPE_ALLOC);
	err = event_accept(ss->ev, s);
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

static int tryudpbind(struct silly_socket *ss, struct socket *s)
{
	int err;
	assert(s->type == STYPE_ALLOC);
	err = event_add(ss->ev, s);
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

int64_t silly_socket_connect(const char *ip, const char *port, const char *bindip,
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
#ifdef SILLY_TEST
	// set sendbuf/recvbuf to 1k for test
	int size = 1024;
	setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, sizeof(size));
	setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, sizeof(size));
#endif
	err = bindfd(fd, IPPROTO_TCP, bindip, bindport);
	if (unlikely(err < 0))
		goto end;
	s = allocsocket(SSOCKET, fd, STYPE_ALLOC, PROTOCOL_TCP);
	if (unlikely(s == NULL))
		goto end;
	cmd.type = 'C';
	cmd.sid = s->sid;
	memcpy(&cmd.addr, info->ai_addr, info->ai_addrlen);
	cmdbuf_write(SSOCKET, &cmd, sizeof(cmd));
	freeaddrinfo(info);
	return s->sid;
end:
	if (fd >= 0)
		closesocket(fd);
	freeaddrinfo(info);
	return -1;
}

int64_t silly_socket_udpconnect(const char *ip, const char *port,
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
	cmdbuf_write(SSOCKET, &cmd, sizeof(cmd));
	freeaddrinfo(info);
	return s->sid;
end:
	if (fd >= 0)
		closesocket(fd);
	freeaddrinfo(info);
	silly_log_error(fmt, ip, port, errno);
	return -1;
}

static void tryudpconnect(struct silly_socket *ss, struct socket *s)
{
	int err;
	assert(s->fd >= 0);
	assert(s->type == STYPE_SOCKET);
	assert(s->protocol == PROTOCOL_UDP);
	err = event_add(ss->ev, s);
	if (unlikely(err < 0)) {
		report_close(ss, s, errno);
		freesocket(ss, s);
	}
	return;
}

int silly_socket_close(int64_t sid)
{
	int type;
	struct cmdkick cmd;
	struct socket *s = socketpool_get(&SSOCKET->pool, sid);
	type = s->type;
	if (unlikely(type == STYPE_FREE)) {
		silly_log_warn(
			"[socket] silly_socket_close reserve socket:%llu\n", sid);
		return -1;
	}
	cmd.type = 'K';
	cmd.sid = sid;
	cmdbuf_write(SSOCKET, &cmd, sizeof(cmd));
	return 0;
}

static int tryclose(struct silly_socket *ss, struct socket *s)
{
	int type;
	(void)ss;
	type = s->type;
	if (unlikely(type == STYPE_FREE)) {
		silly_log_error("[socket] tryclose unsupport "
				"type %d:%lld\n", type, s->sid);
		return -1;
	}
	event_read_enable(ss->ev, s, 0);
	set_close_local(s);
	if (s->protocol == PROTOCOL_TCP && s->fd > 0) {
		shutdown(s->fd, SHUT_RD);
	}
	return 0;
}

int silly_socket_send(int64_t sid, uint8_t *buf, size_t sz,
		      silly_finalizer_t finalizer)
{
	int type;
	struct cmdsend cmd;
	struct socket *s = socketpool_get(&SSOCKET->pool, sid);
	finalizer = finalizer ? finalizer : silly_free;
	if (unlikely(s->protocol != PROTOCOL_TCP)) {
		finalizer(buf);
		silly_log_error("[socket] silly_socket_send invalid sid:%llu\n",
				sid);
		return -1;
	}
	type = s->type;
	if (unlikely(!(type == STYPE_SOCKET || type == STYPE_ALLOC))) {
		finalizer(buf);
		silly_log_error("[socket] silly_socket_send incorrect type "
				"sid:%llu type:%d\n",
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
	cmdbuf_write(SSOCKET, &cmd, sizeof(cmd));
	return 0;
}

int silly_socket_udpsend(int64_t sid, uint8_t *buf, size_t sz, const uint8_t *addr,
			 size_t addrlen, silly_finalizer_t finalizer)
{
	int type;
	struct cmdudpsend cmd;
	struct socket *s = socketpool_get(&SSOCKET->pool, sid);
	finalizer = finalizer ? finalizer : silly_free;
	if (unlikely(s->protocol != PROTOCOL_UDP)) {
		finalizer(buf);
		silly_log_error("[socket] silly_socket_udpsend invalid sid:%llu\n",
				sid);
		return -1;
	}
	type = s->type;
	if (unlikely(!(type == STYPE_SOCKET || type == STYPE_UDPBIND ||
		       type == STYPE_ALLOC))) {
		finalizer(buf);
		silly_log_error("[socket] silly_socket_send incorrect type "
				"sid:%llu type:%d\n",
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
	cmdbuf_write(SSOCKET, &cmd, sizeof(cmd));
	return 0;
}

static int trysend(struct silly_socket *ss, struct socket *s, struct cmdsend *cmd)
{
	uint8_t *data = cmd->data;
	size_t sz = cmd->size;
	silly_finalizer_t finalizer = cmd->finalizer;
	if (unlikely(s->protocol != PROTOCOL_TCP)) {
		finalizer(data);
		silly_log_error("[socket] trysend incorrect socket "
				"sid:%llu type:%d\n",
				s->sid, s->protocol);
		return 0;
	}
	if (unlikely(s->type != STYPE_SOCKET || is_close_local(s))) {
		finalizer(data);
		silly_log_error("[socket] trysend incorrect type "
				"sid:%llu type:%d\n",
				s->sid, s->type);
		return 0;
	}
	ss->netstat.sendsize += sz;
	event_tcpsend(ss->ev, s, data, sz, finalizer);
	return 0;
}

static int tryudpsend(struct silly_socket *ss, struct socket *s, struct cmdudpsend *cmd)
{
	size_t size;
	uint8_t *data;
	union sockaddr_full *addr;
	silly_finalizer_t finalizer;
	finalizer = cmd->send.finalizer;
	data = cmd->send.data;
	if (unlikely(s->protocol != PROTOCOL_UDP)) {
		finalizer(data);
		silly_log_error("[socket] tryudpsend incorrect socket "
				"sid:%llu type:%d\n",
				s->sid, s->protocol);
		return 0;
	}
	if (unlikely(s->type != STYPE_SOCKET && s->type != STYPE_UDPBIND)) {
		finalizer(data);
		silly_log_error("[socket] tryudpsend incorrect type "
				"sid:%llu type:%d\n",
				s->sid, s->type);
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
	event_udpsend(ss->ev, s, data, size, finalizer, addr);
	return 0;
}

void silly_socket_terminate()
{
	struct cmdterm cmd;
	cmd.type = 'T';
	cmd.sid = 0;
	cmdbuf_write(SSOCKET, &cmd, sizeof(cmd));
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

/**
 * Process commands from the command buffer
 * Returns: 0 on success, positive for close, negative for termination
 */
static int cmd_process(struct silly_socket *ss, struct socket **closing)
{
	int nudge;
	uint8_t *ptr, *end;
	struct array *cmdbuf;
	cmdbuf = cmdbuf_read(ss);
	if (cmdbuf->size == 0)
		return 0;
	nudge = event_nudge(ss->ev);
	assert(nudge > 0);
	while (nudge > 0) {
		ptr = cmdbuf->buf;
		end = ptr + cmdbuf->size;
		while (ptr < end) {
			struct cmdpacket *cmd = (struct cmdpacket *)ptr;
			struct socket *s = socketpool_get(&ss->pool, cmd->u.sid);
			switch (cmd->u.type) {
			case 'L':
				trylisten(ss, s);
				ptr += sizeof(cmd->u.listen);
				break;
			case 'B':
				tryudpbind(ss, s);
				ptr += sizeof(cmd->u.listen);
				break;
			case 'C':
				ss->netstat.connecting++;
				event_connect(ss->ev, s, &cmd->u.connect.addr);
				ptr += sizeof(cmd->u.connect);
				break;
			case 'O':
				tryudpconnect(ss, s);
				ptr += sizeof(cmd->u.open);
				break;
			case 'K':
				if (tryclose(ss, s) == 0) {
					s->next = *closing;
					*closing = s;
				}
				ptr += sizeof(cmd->u.kick);
				break;
			case 'S':
				if (trysend(ss, s, &cmd->u.send) < 0) {
					set_close_remote(s);
					s->next = *closing;
					*closing = s;
				}
				ptr += sizeof(cmd->u.send);
				break;
			case 'U':
				//udp socket can only be closed active
				tryudpsend(ss, s, &cmd->u.udpsend);
				ptr += sizeof(cmd->u.udpsend);
				break;
			case 'R':
				event_read_enable(ss->ev, s, cmd->u.readctrl.ctrl);
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
		if (--nudge <= 0) {
			break;
		}
		cmdbuf = cmdbuf_read(ss);
	}
	return 0;
}

int silly_socket_poll()
{
	int err, n;
	struct xevent *events;
	struct socket *closing = NULL;
	struct silly_socket *ss = SSOCKET;
	struct event *ev = ss->ev;
	event_wait(ev);
	err = cmd_process(ss, &closing);
	if (err < 0)
		return err;
	events = event_process(ev, &n);
	for (int i = 0; i < n; i++) {
		struct xevent *e = &events[i];
		switch (e->op) {
		case XEVENT_ACCEPT:
			report_accept(ss, e);
			break;
		case XEVENT_CONNECT:
			ss->netstat.connecting--;
			if (e->err == 0) {
				assert(!is_close_remote(e->s));
				assert(e->s->type == STYPE_ALLOC);
				e->s->type = STYPE_SOCKET;
				report_connected(ss, e->s);
			}
			break;
		case XEVENT_READ:
			ss->netstat.recvsize += e->len;
			if (e->s->protocol == PROTOCOL_TCP) {
				report_data(ss, e->s, SILLY_SDATA, e->buf, e->len);
			} else if (e->s->protocol == PROTOCOL_UDP) {
				report_data(ss, e->s, SILLY_SUDP, e->buf, e->len);
			}
			break;
		case XEVENT_CLOSE:
		case XEVENT_NONE:
			break;
		}
		if (e->s->next == NULL && is_close_any(e->s)) {
			e->s->next = closing;
			closing = e->s;
		}
	}
	while (closing != NULL) {
		struct socket *s = closing;
		closing = s->next;
		s->next = NULL;
		assert(is_close_any(s));
		if (!wlist_empty(s)) {
			continue;
		}
		if (!is_close_local(s)) {
			report_close(ss, s, 0);
		}
		freesocket(ss, s);
	}
	return 0;
}

int silly_socket_init()
{
	struct silly_socket *ss;
	struct event *ev;
	ev = event_new(EVENT_SIZE);
	if (ev == NULL)
		return -errno;
	ss = silly_malloc(sizeof(*ss));
	memset(ss, 0, sizeof(*ss));
	socketpool_init(&ss->pool);
	ss->ev = ev;
	cmdbuf_init(&ss->cmdbuf, CMDBUF_SIZE);
	SSOCKET = ss;
	return 0;
}

void silly_socket_exit()
{
	assert(SSOCKET);
	event_free(SSOCKET->ev);
	cmdbuf_destroy(&SSOCKET->cmdbuf);
	socketpool_destroy(&SSOCKET->pool);
	silly_free(SSOCKET);
	return;
}

const char *silly_socket_pollapi()
{
	return SOCKET_POLL_API;
}

int silly_socket_ctrlcount()
{
	//TODO:
	return 0;
}

struct silly_netstat *silly_socket_netstat()
{
	return &SSOCKET->netstat;
}

void silly_socket_socketstat(int64_t sid, struct silly_socketstat *info)
{
	struct socket *s;
	s = socketpool_get(&SSOCKET->pool, sid);
	memset(info, 0, sizeof(*info));
	info->sid = s->sid;
	info->fd = s->fd;
	info->type = stype_name[s->type];
	info->protocol = protocol_name[s->protocol];
	if (s->fd >= 0) {
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
