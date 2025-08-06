#ifndef _EVENT_H
#define _EVENT_H

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


#include <stdint.h>

#include "socket.h"

enum xevent_op {
	XEVENT_NONE = 0,
	XEVENT_ACCEPT = 1,
	XEVENT_CONNECT = 2,
	XEVENT_READ = 3,
	XEVENT_CLOSE = 4,
};

struct xevent {
	enum xevent_op op;
	union {
		uint32_t len;
		uint32_t err;
		fd_t fd;
	};
	void *buf;
	struct socket *s;
	union sockaddr_full addr;
};

struct event;

struct event *event_new(int nr);
void event_free(struct event *ev);
void event_wait(struct event *ev);
void event_wakeup(struct event *ev);
int event_nudge(struct event *ev);
int event_add(struct event *ev, struct socket *s);
void event_read_enable(struct event *ev, struct socket *s, int enable);
int event_accept(struct event *ev, struct socket *s);
void event_connect(struct event *ev, struct socket *s, union sockaddr_full *addr);
void event_tcpsend(struct event *ev, struct socket *s, uint8_t *data, size_t sz, void (*finalizer)(void *));
void event_udpsend(struct event *ev, struct socket *s, uint8_t *data,
	size_t size, void (*finalizer)(void *), const union sockaddr_full *addr);
struct xevent *event_process(struct event *ev, int *n);


#endif
