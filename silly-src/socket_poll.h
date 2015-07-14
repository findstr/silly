#ifndef _SOCKET_POLL_H
#define _SOCKET_POLL_H

#ifdef  __os_linux__
#include <sys/epoll.h>

#define SP_READ(e)   (e->events & EPOLLIN)
#define SP_WRITE(e)  (e->events & EPOLLOUT)
#define SP_ERR(e)    (e->events & (EPOLLERR || EPOLLHUP))

typedef struct epoll_event sp_event_t;

static inline int
_sp_create(int nr)
{
        return epoll_create(nr);
}

static inline int
_sp_wait(int sp, sp_event_t *event_buff, int cnt)
{
        int ret;
        ret = epoll_wait(sp, event_buff, cnt, -1);
        return ret;
}

static inline int
_sp_add(int sp, int fd, void *ud)
{
        struct epoll_event      event;
        event.data.ptr = ud;
        event.events = EPOLLIN;
        return epoll_ctl(sp, EPOLL_CTL_ADD, fd, &event);
}

static inline int
_sp_del(int sp, int fd)
{
        return epoll_ctl(sp, EPOLL_CTL_DEL, fd, NULL);
}

static inline int
_sp_write_enable(int sp, int fd, void *ud, int enable)
{
        struct epoll_event      event;
        event.data.ptr = ud;
        if (enable == 1)
                event.events = EPOLLIN | EPOLLOUT;
        else
                event.events = EPOLLIN;

        return epoll_ctl(sp, EPOLL_CTL_MOD, fd, &event);
}


#else

#include <sys/event.h>

typedef struct kevent sp_event_t;

static inline int
_sp_create(int nr)
{
        (void)nr;
        return kqueue();
}

static inline int
_sp_wait(int sp, sp_event_t *event_buff, int cnt)
{
        int ret;
        ret = kevent(sp, NULL, 0, event_buff, cnt, NULL);
        return ret;
}

static inline int
_sp_add(int sp, int fd, void *ud)
{
        struct kevent event[1];
        EV_SET(&event[0], fd, EVFILT_READ, EV_ADD, 0, 0, ud);

        return kevent(sq, event, 1, NULL, 0, NULL);
}

static inline int
_sp_write_enable(int sp, int fd, void *ud, int enable)
{
        struct kevent event[1];
        int ctrl = enable ? EV_ENABLE : EV_DISABLE;
        (void)ud;

        EV_SET(&event[0], fd, EVFILT_WRITE, ctrl, 0, 0, NULL);
        return kevent(kq, event, 1, NULL, 0, NULL);
}

#endif


#endif

