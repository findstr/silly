#ifndef _EVENT_EPOLL_H
#define _EVENT_EPOLL_H
#include <sys/epoll.h>

#define SP_IN EPOLLIN
#define SP_OUT EPOLLOUT

#define SP_READ(e) (e->events & EPOLLIN)
#define SP_WRITE(e) (e->events & EPOLLOUT)
#define SP_ERR(e) (e->events & (EPOLLERR | EPOLLHUP))
#define SP_UD(e) (e->data.ptr)
#define SP_INVALID (-1)

typedef int fd_t;
typedef struct epoll_event event_t;

static inline fd_t sp_create(int nr)
{
	return epoll_create(nr);
}

static inline void sp_free(fd_t fd)
{
	close(fd);
}

static inline int sp_wait(fd_t sp, event_t *event_buff, int cnt)
{
	int ret;
	ret = epoll_wait(sp, event_buff, cnt, -1);
	return ret;
}

static inline int sp_add(fd_t sp, fd_t fd, void *ud)
{
	struct epoll_event event;
	event.data.ptr = ud;
	event.events = EPOLLIN;
	return epoll_ctl(sp, EPOLL_CTL_ADD, fd, &event);
}

static inline int sp_del(fd_t sp, fd_t fd)
{
	return epoll_ctl(sp, EPOLL_CTL_DEL, fd, NULL);
}

static inline int sp_ctrl(fd_t sp, fd_t fd, void *ud, int ctrl)
{
	struct epoll_event event;
	event.data.ptr = ud;
	event.events = ctrl;
	return epoll_ctl(sp, EPOLL_CTL_MOD, fd, &event);
}

static inline int sp_read_enable(fd_t sp, fd_t fd, void *ud, int enable)
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
