#ifndef _SOCKET_EPOLL_H
#define _SOCKET_EPOLL_H
#include <sys/epoll.h>

#define SP_READ(e)   (e->events & EPOLLIN)
#define SP_WRITE(e)  (e->events & EPOLLOUT)
#define SP_ERR(e)    (e->events & (EPOLLERR | EPOLLHUP))
#define SP_UD(e)     (e->data.ptr)

#define SP_INVALID   (-1)
typedef int sp_t;
typedef struct epoll_event sp_event_t;

static inline int
sp_create(int nr)
{
	return epoll_create(nr);
}

static inline void
sp_free(sp_t fd)
{
	close(fd);
}

static inline int
sp_wait(sp_t sp, sp_event_t *event_buff, int cnt)
{
	int ret;
	ret = epoll_wait(sp, event_buff, cnt, -1);
	return ret;
}

static inline int
sp_add(sp_t sp, int fd, void *ud)
{
	struct epoll_event event;
	event.data.ptr = ud;
	event.events = EPOLLIN;
	return epoll_ctl(sp, EPOLL_CTL_ADD, fd, &event);
}

static inline int
sp_del(sp_t sp, int fd)
{
	return epoll_ctl(sp, EPOLL_CTL_DEL, fd, NULL);
}

static inline int
sp_write_enable(sp_t sp, int fd, void *ud, int enable)
{
	struct epoll_event event;
	event.data.ptr = ud;
	if (enable == 1)
		event.events = EPOLLIN | EPOLLOUT;
	else
		event.events = EPOLLIN;

	return epoll_ctl(sp, EPOLL_CTL_MOD, fd, &event);
}

#endif

