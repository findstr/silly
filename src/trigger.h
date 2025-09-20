#ifndef _TRIGGER_H
#define _TRIGGER_H

#include <stdint.h>
#include <stdatomic.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <assert.h>

#include "platform.h"
#include "silly_log.h"

struct trigger {
	fd_t sendfd;
	fd_t recvfd;
	atomic_int_fast8_t fired;
};

static inline int trigger_init(struct trigger *t)
{
	fd_t fds[2];
	t->sendfd = -1;
	t->recvfd = -1;
	atomic_init(&t->fired, 0);
	if (pipe(fds) != 0) {
		log_error("[trigger] pipe create error:%s\n", strerror(errno));
		return -1;
	}
	// Note: Non-blocking is not set here since pipe_blockwrite/read are used
	t->recvfd = fds[0];
	t->sendfd = fds[1];
	return 0;
}

static inline void trigger_destroy(struct trigger *t)
{
	if (t->recvfd >= 0) {
		close(t->recvfd);
		t->recvfd = -1;
	}
	if (t->sendfd >= 0) {
		close(t->sendfd);
		t->sendfd = -1;
	}
}

static inline int trigger_fd(struct trigger *t)
{
	return t->recvfd;
}

static inline int trigger_fire(struct trigger *t)
{
	uint8_t n = 0xef;
	for (;;) {
		ssize_t err = pipe_write(t->sendfd, (void *)&n, 1);
		if (err == -1) {
			if (likely(errno == EINTR))
				continue;
			log_error("[trigger] pipe write error:%s\n",
				  strerror(errno));
			return -1;
		}
		assert(err == 1);
		atomic_store_explicit(&t->fired, 1, memory_order_release);
		return 0;
	}
}

static inline int trigger_consume(struct trigger *t)
{
	uint8_t n;
	if (atomic_load_explicit(&t->fired, memory_order_acquire) == 0)
		return 0;
	for (;;) {
		ssize_t err = pipe_read(t->recvfd, &n, sizeof(n));
		if (err == -1) {
			if (likely(errno == EINTR))
				continue;
			log_error("[trigger] pipe read error:%s\n",
				  strerror(errno));
			return -1;
		}
		assert(err == 1);
		atomic_store_explicit(&t->fired, 0, memory_order_relaxed);
		return 1;
	}
}

static inline int trigger_is_fired(struct trigger *t)
{
	return atomic_load_explicit(&t->fired, memory_order_acquire);
}

#endif