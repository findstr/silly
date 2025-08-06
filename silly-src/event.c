#include "silly.h"
#include <assert.h>
#include <stdio.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>

#include "silly.h"
#include "compiler.h"
#include "net.h"
#include "event.h"
#include "pipe.h"
#include "nonblock.h"
#include "silly_malloc.h"
#include "silly_log.h"
#include "socketpool.h"

#if defined(__linux__)

#include "event_epoll.h"
#define SOCKET_POLL_API "epoll"
#endif

#if defined(__MACH__)

#include "event_kevent.h"
#define SOCKET_POLL_API "kevent"

#endif

#if defined(__WIN32)

#include "event_iocp.h"
#define SOCKET_POLL_API "iocp"

#endif

struct event {
	fd_t spfd;
	fd_t reservefd;
	int eventcount;
	int eventcap;
	int xeventcap;
	int xi;
	event_t *eventbuf;
	struct xevent *xeventbuf;
	//ctrl pipe, call write can be automatic
	//when data less then 64k(from APUE)
	int ctrlsendfd;
	int ctrlrecvfd;
	//temp buffer
	uint8_t readbuf[TCP_READ_BUF_SIZE];
};

static void event_rw(struct event *ev, fd_t fd, void *ud, int r, int w)
{
	int err;
	int flag;
	if (likely(r != 0))
		flag = SP_IN;
	else
		flag = 0;
	if (w != 0)
		flag |= SP_OUT;
	err = sp_ctrl(ev->spfd, fd, ud, flag);
	if (unlikely(err < 0)) {
		silly_log_error("[event] event_rw error:%s\n",
				strerror(errno));
	}
}

struct event *event_new(int nr)
{
	int err;
	struct event *ev;
	fd_t fds[2] = { -1, -1 };
	fd_t spfd = sp_create(nr);
	if (spfd == SP_INVALID)
		return NULL;
	err = pipe(fds);
	if (unlikely(err < 0)) {
		sp_free(spfd);
		return NULL;
	}
	//use the pipe and not the socketpair because
	//the pipe will be automatic
	//when the data size small than PIPE_BUF
	err = sp_add(spfd, fds[0], NULL);
	if (unlikely(err < 0)) {
		sp_free(spfd);
		closesocket(fds[0]);
		closesocket(fds[1]);
		return NULL;
	}
	ev = silly_malloc(sizeof(*ev));
	memset(ev, 0, sizeof(*ev));
	ev->reservefd = open("/dev/null", O_RDONLY);
	ev->spfd = spfd;
	ev->ctrlsendfd = fds[1];
	ev->ctrlrecvfd = fds[0];
	ev->eventcount = 0;
	ev->eventcap = nr;
	ev->xeventcap = nr;
	ev->xi = 0;
	ev->eventbuf =
		(event_t *)silly_malloc(sizeof(event_t) * nr);
	ev->xeventbuf =
		(struct xevent *)silly_malloc(sizeof(struct xevent) * nr);
	return ev;
}

void event_free(struct event *ev)
{
	sp_free(ev->spfd);
	closesocket(ev->ctrlsendfd);
	closesocket(ev->ctrlrecvfd);
	closesocket(ev->reservefd);
	silly_free(ev->xeventbuf);
	silly_free(ev->eventbuf);
	silly_free(ev);
}

void event_wait(struct event *ev)
{
	ev->eventcount = sp_wait(ev->spfd, ev->eventbuf, ev->eventcap);
	if (ev->eventcount < 0)
		silly_log_error("[socket] eventwait:%d\n", errno);
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

static struct xevent *push_xevent(struct event *ev, enum xevent_op op, struct socket *s)
{
	struct xevent *xe;
	if (ev->xi >= ev->xeventcap) {
		ev->xeventcap *= 2;
		ev->xeventbuf = (struct xevent *)silly_realloc(ev->xeventbuf, sizeof(struct xevent) * ev->xeventcap);
	}
	xe = &ev->xeventbuf[ev->xi];
	xe->s = s;
	xe->op = op;
	ev->xi++;
	return xe;
}

void event_update_rw(struct event *ev, struct socket *s)
{
	int write_enable = wlist_empty(s) ? 0 : 1;
	event_rw(ev, s->fd, s, is_reading(s), write_enable);
}

static int send_msg_tcp(struct event *ev, struct socket *s)
{
	struct wlist *w;
	w = s->wlhead;
	assert(w);
	while (w) {
		ssize_t sz;
		assert(w->size > s->wloffset);
		sz = sendn(s->fd, w->buf + s->wloffset, w->size - s->wloffset);
		if (unlikely(sz < 0)) {
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
			event_update_rw(ev, s);
		}
	}
	return 0;
}

static int send_msg_udp(struct event *ev, struct socket *s)
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
			event_update_rw(ev, s);
		}
	}
	return 0;
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

static void report_accept(struct event *ev, struct socket *s)
{
	int fd;
	struct xevent *xe;
	union sockaddr_full addr;
	socklen_t len = sizeof(addr);
#ifndef USE_ACCEPT4
	fd = accept(s->fd, &addr.sa, &len);
#else
	fd = accept4(s->fd, &addr.sa, &len, SOCK_NONBLOCK);
#endif
	if (unlikely(fd < 0)) {
		if (errno != EMFILE && errno != ENFILE)
			return;
		closesocket(ev->reservefd);
		fd = accept(s->fd, NULL, NULL);
		closesocket(fd);
		silly_log_error(
			"[socket] accept reach limit of file descriptor\n");
		ev->reservefd = open("/dev/null", O_RDONLY);
		return;
	}
#ifndef USE_ACCEPT4
	nonblock(fd);
#endif
	keepalive(fd);
	nodelay(fd);
	xe = push_xevent(ev, XEVENT_ACCEPT, s);
	xe->fd = fd;
	xe->addr = addr;
}

static inline int checkconnected(struct event *ev, struct socket *s)
{
	int ret, err;
	socklen_t errlen = sizeof(err);
	assert(s->fd >= 0);
	ret = getsockopt(s->fd, SOL_SOCKET, SO_ERROR, (void *)&err, &errlen);
	if (unlikely(ret < 0)) {
		silly_log_error("[socket] checkconnected:%s\n",
				strerror(errno));
		return -errno;
	}
	if (unlikely(err != 0)) {
		err = translate_socket_errno(err);
		silly_log_error("[socket] checkconnected:%s\n", strerror(err));
		return -err;
	}
	set_reading(s);
	event_update_rw(ev, s);
	return 0;
}

struct xevent *event_process(struct event *ev, int *n)
{
	event_t *e;
	ssize_t sz;
	struct xevent *xe;
	struct socket *s;
	socklen_t addrlen;
	union sockaddr_full addr;
	for (int i = 0; i < ev->eventcount; i++) {
		int ret = 0;
		e = &ev->eventbuf[i];
		s = SP_UD(e);
		if (s == NULL) //the socket event has be cleared, TODO: this is control pipe
			continue;
		switch (s->type) {
		case STYPE_LISTEN:
			if (is_close_local(s)) {
				continue;
			}
			assert(SP_READ(e));
			report_accept(ev, s);
			continue;
		case STYPE_FREE:
			silly_log_error("[socket] poll reserve socket\n");
			continue;
		case STYPE_SOCKET:
		case STYPE_UDPBIND:
		case STYPE_ALLOC:
			break;
		default:
			silly_log_error(
				"[socket] poll: unkonw socket type:%d\n",
				s->type);
			continue;
		}
		if (SP_READ(e) && !is_close_local(s)) {
			switch (s->protocol) {
			case PROTOCOL_TCP:
				sz = readn(s->fd, ev->readbuf, sizeof(ev->readbuf));
				break;
			case PROTOCOL_UDP:
				sz = readudp(s->fd, ev->readbuf, sizeof(ev->readbuf), &addr, &addrlen);
				break;
			default:
				silly_log_error("[socket] poll:"
						"unsupport protocol:%d\n",
						s->protocol);
				continue;
			}
			if (sz > 0) {
				xe = push_xevent(ev, XEVENT_READ, s);
				if (s->protocol == PROTOCOL_TCP) {
					xe->buf = silly_malloc(sz);
					xe->len = sz;
					memcpy(xe->buf, ev->readbuf, sz);
				} else {
					int sa_len = SA_LEN(addr.sa);
					xe->buf = silly_malloc(sz+sa_len);
					xe->len = sz;
					memcpy(xe->buf, ev->readbuf, sz);
					memcpy(xe->buf + sz, &addr, sa_len);
				}
			} else if (sz < 0) {
				ret = -1;
			}
		}
		if (SP_WRITE(e) && !is_close_remote(s)) {
			if (s->protocol == PROTOCOL_TCP) {
				if (is_connecting(s)) {
					clear_connecting(s);
					ret = checkconnected(ev, s);
					xe = push_xevent(ev, XEVENT_CONNECT, s);
					xe->err = -ret;
					ret = 0;
				} else {
					ret = send_msg_tcp(ev, s);
				}
			} else {
				ret = send_msg_udp(ev, s);
			}
		}
		if (ret < 0 || SP_ERR(e)) {
			set_close_remote(s);
			wlist_free(s);
			closesocket(s->fd);
			sp_del(ev->spfd, s->fd);
			s->fd = -1;
			push_xevent(ev, XEVENT_CLOSE, s);
			continue;
		}

		if (is_close_local(s) && wlist_empty(s)) {
			set_close_remote(s);
			wlist_free(s);
			closesocket(s->fd);
			sp_del(ev->spfd, s->fd);
			s->fd = -1;
			push_xevent(ev, XEVENT_CLOSE, s);
		}
	}
	*n = ev->xi;
	ev->xi = 0;
	return ev->xeventbuf;
}

void event_wakeup(struct event *ev)
{
	uint8_t val = 0;
	for (;;) {
		ssize_t err = pipe_write(ev->ctrlsendfd, &val, 1);
		if (err == -1) {
			if (likely(errno == EINTR || errno == EAGAIN))
				continue;
			silly_log_error("[socket] pipe_blockwrite error:%s",
					strerror(errno));
			return;
		}
		assert(err == 1);
		return;
	}
}

int event_nudge(struct event *ev)
{
	uint8_t val;
	for (;;) {
		ssize_t err = pipe_read(ev->ctrlrecvfd, &val, 1);
		if (err == -1) {
			if (likely(errno == EINTR || errno == EAGAIN))
				continue;
			silly_log_error("[event] event_nudge error:%s\n",
					strerror(errno));
			return 0;
		}
		assert(err == 1);
		return 1;
	}
}

int event_add(struct event *ev, struct socket *s)
{
	int err;
	err = sp_add(ev->spfd, s->fd, s);
	if (unlikely(err < 0)) {
		silly_log_error("[event] event_add error:%s\n",
				strerror(errno));
		return -1;
	}
	set_reading(s);
	return 0;
}

void event_read_enable(struct event *ev, struct socket *s, int enable)
{
	int writing;
	if (is_reading(s) == enable)
		return;
	if (enable) {
		set_reading(s);
	} else {
		clear_reading(s);
	}
	writing = (!wlist_empty(s) || is_connecting(s)) ? 1 : 0;
	event_rw(ev, s->fd, s, enable, writing);
}

int event_del(struct event *ev, fd_t fd)
{
	int err;
	err = sp_del(ev->spfd, fd);
	if (unlikely(err < 0)) {
		silly_log_error("[event] event_del error:%s\n",
				strerror(errno));
		return -1;
	}
	return 0;
}

void event_connect(struct event *ev, struct socket *s, union sockaddr_full *addr)
{
	int err;
	fd_t fd;
	assert(s->fd >= 0);
	assert(s->type == STYPE_ALLOC);
	fd = s->fd;
	nonblock(fd);
	keepalive(fd);
	nodelay(fd);
	err = connect(fd, &addr->sa, SA_LEN(addr->sa));
	if (unlikely(err == -1 && errno != CONNECT_IN_PROGRESS)) { //error
		struct xevent *xe;
		xe = push_xevent(ev, XEVENT_CONNECT, s);
		xe->err = -errno;
		xe->addr = *addr;
		set_close_remote(s);
		return;
	} else if (err == 0) { //connect
		struct xevent *xe;
		err = event_add(ev, s);
		if (unlikely(err < 0)) {
			set_close_remote(s);
		}
		xe = push_xevent(ev, XEVENT_CONNECT, s);
		xe->err = err;
		xe->addr = *addr;
	} else { //block
		set_connecting(s);
		err = event_add(ev, s);
		if (unlikely(err < 0)) {
			set_close_remote(s);
		} else {
			event_rw(ev, s->fd, s, is_reading(s), 1);
		}
	}
}

void event_tcpsend(struct event *ev, struct socket *s, uint8_t *data, size_t sz, void (*finalizer)(void *))
{
	if (wlist_empty(s) && s->type == STYPE_SOCKET) { //try send
		ssize_t n = sendn(s->fd, data, sz);
		if (n < 0) {
			finalizer(data);
			return;
		} else if ((size_t)n < sz) {
			s->wloffset = n;
			wlist_append(s, data, sz, finalizer);
			event_update_rw(ev, s);
		} else {
			assert((size_t)n == sz);
			finalizer(data);
		}
	} else {
		wlist_append(s, data, sz, finalizer);
	}
	return;
}

void event_udpsend(struct event *ev, struct socket *s, uint8_t *data,
	size_t size, void (*finalizer)(void *), const union sockaddr_full *addr)
{
	if (wlist_empty(s)) { //try send
		ssize_t n = sendudp(s->fd, data, size, addr);
		if (n == -1 || n >= 0) { //occurs error or send ok
			finalizer(data);
			return;
		}
		assert(n == -2); //EAGAIN
		wlist_appendudp(s, data, size, finalizer, addr);
		event_update_rw(ev, s);
	} else {
		wlist_appendudp(s, data, size, finalizer, addr);
	}
	return;
}
