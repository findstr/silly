#ifndef _SOCKET_KEVENT_H
#define _SOCKET_KEVENT_H

#include <sys/event.h>

#define SP_IN        (1U)
#define SP_OUT       (2U)

#define SP_READ(e)   (e->filter == EVFILT_READ)
#define SP_WRITE(e)  (e->filter == EVFILT_WRITE)
#define SP_ERR(e)    ((e->filter != EVFILT_READ) && (e->filter != EVFILT_WRITE))
#define SP_UD(e)     (e->udata)

#define SP_INVALID   (-1)
typedef int sp_t;
typedef struct kevent sp_event_t;

static inline int
sp_create(int nr)
{
	(void)nr;
	return kqueue();
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
	ret = kevent(sp, NULL, 0, event_buff, cnt, NULL);
	return ret;
}

static inline int
sp_del(sp_t sp, int fd)
{
	struct kevent event[1];
	EV_SET(&event[0], fd, EVFILT_READ, EV_DELETE, 0, 0, NULL);
	kevent(sp, event, 1, NULL, 0, NULL);
	EV_SET(&event[0], fd, EVFILT_WRITE, EV_DELETE, 0, 0, NULL);
	kevent(sp, event, 1, NULL, 0, NULL);

	return 0;
}


static inline int
sp_ctrl(sp_t sp, int fd, void *ud, int flag)
{
	#define bit(n, flag)	(((n) & flag) ? EV_ENABLE : EV_DISABLE)
	struct kevent events[2];
	EV_SET(&events[0], fd, EVFILT_READ, bit(flag, SP_IN), 0, 0, ud);
	EV_SET(&events[1], fd, EVFILT_WRITE, bit(flag, SP_OUT), 0, 0, ud);
	return kevent(sp, events, 2, NULL, 0, NULL);
	#undef bit
}


static inline int
sp_add(sp_t sp, int fd, void *ud)
{
	int ret;
	struct kevent event[1];
	EV_SET(&event[0], fd, EVFILT_READ, EV_ADD, 0, 0, ud);
	ret = kevent(sp, event, 1, NULL, 0, NULL);
	if (ret == -1)
		return -1;

	EV_SET(&event[0], fd, EVFILT_WRITE, EV_ADD, 0, 0, ud);
	ret = kevent(sp, event, 1, NULL, 0, NULL);
	if (ret == -1) {
		EV_SET(&event[0], fd, EVFILT_READ, EV_DELETE, 0, 0, ud);
		kevent(sp, event, 1, NULL, 0, NULL);
	}
	ret = sp_ctrl(sp, fd, ud, SP_IN);
	if (ret == -1)
		sp_del(sp, fd);
	return ret;
}

#endif

