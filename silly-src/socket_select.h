#ifndef _SOCKET_SELECT_H
#define _SOCKET_SELECT_H

#if __WIN32__
#include <winsock2.h>
#else
#include <netdb.h>
#include <arpa/inet.h>
#include <netinet/tcp.h>
#include <sys/types.h>
#include <sys/socket.h>
#endif

#define SP_INVALID	NULL
#define SP_RD_FLAG	0x01
#define SP_WR_FLAG	0x02
#define SP_ER_FLAG	0x04
#define SP_MAX		64

#define SP_READ(e)   (e->rwstatus & SP_RD_FLAG)
#define SP_WRITE(e)  (e->rwstatus & SP_WR_FLAG)
#define SP_ERR(e)    (e->rwstatus & SP_ER_FLAG)
#define SP_UD(e)     (e->ud)

typedef struct sp_event {
	int fd;
	int rwctrl; /* 0x01 --> read, 0x02 --> write */
	int rwstatus; /* 0x01 --> read, 0x02 --> write, 0x04 --> error*/
	void *ud;
} sp_event_t;

typedef struct sp_poll {
	sp_event_t event[SP_MAX];
} *sp_t;


static inline sp_t
sp_create(int nr)
{
	int i;
	sp_t sp = silly_malloc(sizeof(struct sp_poll));
	for (i = 0; i < SP_MAX; i++) {
		sp->event[i].fd = -1;
		sp->event[i].rwstatus = 0;
		sp->event[i].ud = NULL;
	}
	return sp;
}

static inline void
sp_free(sp_t fd)
{
	silly_free(fd);
}

static inline int
sp_wait(sp_t sp, sp_event_t *event_buff, int cnt)
{
	int i;
	int ei;
	int err;
	int max = 0;
	fd_set rfds;
	fd_set wfds;
	fd_set efds;
	FD_ZERO(&rfds);
	FD_ZERO(&wfds);
	FD_ZERO(&efds);

	for (i = 0; i < SP_MAX; i++) {
		int fd = sp->event[i].fd;
		if (fd > max)
			max = fd;
		if (sp->event[i].rwctrl & SP_RD_FLAG)
			FD_SET(fd, &rfds);
		if (sp->event[i].rwctrl & SP_WR_FLAG)
			FD_SET(fd, &wfds);
		FD_SET(fd, &efds);
	}
	err = select(max + 1, &rfds, &wfds, &efds, NULL);
	if (err < 0)
		return -1;
	ei = 0;
	for (i = 0; i < SP_MAX; i++) {
		int fd = sp->event[i].fd;
		event_buff[ei].rwstatus = 0;
		if (FD_ISSET(fd, &rfds))
			event_buff[ei].rwstatus |= SP_RD_FLAG;
		if (FD_ISSET(fd, &wfds))
			event_buff[ei].rwstatus |= SP_WR_FLAG;
		if (FD_ISSET(fd, &efds))
			event_buff[ei].rwstatus |= SP_ER_FLAG;
		if (event_buff[ei].rwstatus) {
			event_buff[ei].fd = sp->event[i].fd;
			event_buff[ei].ud = sp->event[i].ud;
			ei++;
		}
	}
	return ei;
}

static inline int
sp_add(sp_t sp, int fd, void *ud)
{
	int i;
	for (i = 0; i < SP_MAX; i++) {
		if (sp->event[i].fd < 0) {
			sp->event[i].fd = fd;
			sp->event[i].rwctrl = SP_RD_FLAG;
			sp->event[i].ud = ud;
			return 0;
		}
	}
	return -1;
}

static inline int
sp_del(sp_t sp, int fd)
{
	int i;
	for (i = 0; i < SP_MAX; i++) {
		if (sp->event[i].fd == fd) {
			sp->event[i].fd = -1;
			return 0;
		}
	}
	return -1;
}

static inline int
sp_write_enable(sp_t sp, int fd, void *ud, int enable)
{
	int i;
	for (i = 0; i < SP_MAX; i++) {
		if (sp->event[i].fd < 0) {
			assert(sp->event[i].fd == fd);
			if (enable)
				sp->event[i].rwctrl |= SP_WR_FLAG;
			else
				sp->event[i].rwctrl &= ~SP_WR_FLAG;
			return 0;
		}
	}
	return -1;
}

#endif

