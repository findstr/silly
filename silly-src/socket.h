#ifndef _SOCKET_H
#define _SOCKET_H

#include "compiler.h"
#include "atomic.h"
#include "spinlock.h"
#include "silly_malloc.h"
#include "net.h"

#define PROTOCOL_TCP 1
#define PROTOCOL_UDP 2

enum stype {
	STYPE_FREE,
	STYPE_ALLOC,
	STYPE_LISTEN,   //listen fd
	STYPE_UDPBIND,  //listen fd(udp)
	STYPE_SOCKET,   //socket normal status
};

#define SOCKET_CONNECTING   (1U << 0)
#define SOCKET_READING      (1U << 1)
#define SOCKET_WRITING      (1U << 2)
#define SOCKET_CLOSE_LOCAL  (1U << 3)
#define SOCKET_CLOSE_REMOTE (1U << 4)
#define SOCKET_CLOSE_BOTH   (SOCKET_CLOSE_LOCAL | SOCKET_CLOSE_REMOTE)

#define is_connecting(s) ((s->flags & SOCKET_CONNECTING) != 0)
#define set_connecting(s) (s->flags |= SOCKET_CONNECTING)
#define clear_connecting(s) (s->flags &= ~SOCKET_CONNECTING)

#define is_reading(s) ((s->flags & SOCKET_READING) != 0)
#define set_reading(s) (s->flags |= SOCKET_READING)
#define clear_reading(s) (s->flags &= ~SOCKET_READING)

#define is_writing(s) ((s->flags & SOCKET_WRITING) != 0)
#define set_writing(s) (s->flags |= SOCKET_WRITING)
#define clear_writing(s) (s->flags &= ~SOCKET_WRITING)

#define set_close_local(s) (s->flags |= SOCKET_CLOSE_LOCAL)
#define is_close_local(s) ((s->flags & SOCKET_CLOSE_LOCAL) != 0)

#define set_close_remote(s) (s->flags |= SOCKET_CLOSE_REMOTE)
#define is_close_remote(s) ((s->flags & SOCKET_CLOSE_REMOTE) != 0)

#define is_close_both(s) ((s->flags & SOCKET_CLOSE_BOTH) == SOCKET_CLOSE_BOTH)
#define is_close_any(s) ((s->flags & SOCKET_CLOSE_BOTH) != 0)

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
	void (*finalizer)(void *ptr);
	union sockaddr_full *udpaddress;
};

struct mvec {
	struct iovec *iov;
	void (**finv)(void *);
	int offset;
	/* length of allocated vec */
	int cap;
	/* length currently being used */
	int len;
	/* only for send, current index we're processing */
	int curiov;
};

struct iomsg {
	struct msghdr hdr;
	struct mvec vecs[2];
	/* current msg_vec being prepared */
	int sending;
};

struct socket {
	int64_t sid; //socket descriptor
	fd_t fd;
	uint32_t version;
	uint8_t protocol;
	uint8_t flags;
	uint8_t type;
	size_t wloffset;
	struct wlist *wlhead;
	struct wlist **wltail;
	struct socket *next;
	struct iomsg sendmsg; //used for sendmsg
};

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

static inline void wlist_append(struct socket *s, uint8_t *buf, size_t size,
				void (*finalizer)(void *ptr))
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
				   void (*finalizer)(void *ptr),
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

static void mvec_free(struct mvec *mvec)
{
	for (int i = 0; i < mvec->len; i++) {
		if (mvec->finv[i]) {
			mvec->finv[i](mvec->iov[i].iov_base);
		}
	}
	silly_free(mvec->iov);
	silly_free(mvec->finv);
	mvec->iov = NULL;
	mvec->finv = NULL;
}

static void mvec_init(struct mvec *mvec)
{
	memset(mvec, 0, sizeof(*mvec));
	mvec->cap = 8;
	mvec->iov = silly_malloc(mvec->cap * sizeof(mvec->iov[0]));
	mvec->finv = silly_malloc(mvec->cap * sizeof(mvec->finv[0]));
}

static void iomsg_free(struct iomsg *msg)
{
	mvec_free(&msg->vecs[0]);
	mvec_free(&msg->vecs[1]);
	msg->sending = 0;
}

static void iomsg_append(struct iomsg *msg, void *buf,
	size_t sz, void (*fin)(void *))
{
	int prepare = 1 - msg->sending;
	struct mvec *mvec = &msg->vecs[prepare];
	if (mvec->len >= mvec->cap) {
		mvec->cap *= 2;
		mvec->iov = silly_realloc(mvec->iov, mvec->cap * sizeof(mvec->iov[0]));
		mvec->finv = silly_realloc(mvec->finv, mvec->cap * sizeof(mvec->finv[0]));
	}
	mvec->iov[mvec->len].iov_base = buf;
	mvec->iov[mvec->len].iov_len = sz;
	mvec->finv[mvec->len] = fin;
	mvec->len++;
}

static void iomsg_isempty(struct iomsg *msg)
{
	struct mvec *mvec = &msg->vecs[msg->sending];
	return mvec->curiov >= mvec->len;
}

static void iomsg_flip(struct iomsg *msg)
{
	struct mvec *mvec = &msg->vecs[msg->sending];
	assert(mvec->len == mvec->curiov);
	mvec->len = 0;
	mvec->curiov = 0;
	mvec->offset = 0;
	msg->sending = 1 - msg->sending;
	assert(msg->vecs[msg->sending].offset == 0);
}

#endif
