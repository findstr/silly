#ifndef _SILLY_WIN_H
#define _SILLY_WIN_H

#include <winsock2.h>
#include <ws2tcpip.h>
#include <iphlpapi.h>
#include <ws2def.h>
#include <io.h>
#include <limits.h>
#include "log.h"

typedef intptr_t fd_t;

/* iovec / writev emulation via WSASend */
struct iovec {
	void *iov_base;
	size_t iov_len;
};

static inline ssize_t writev(fd_t fd, const struct iovec *iov, int iovcnt)
{
	int so_type = 0;
	int so_type_len = (int)sizeof(so_type);
	DWORD sent = 0;

	/* Socket path: use WSASend (supports scatter/gather efficiently). */
	if (getsockopt((SOCKET)fd, SOL_SOCKET, SO_TYPE, (char *)&so_type,
		       &so_type_len) == 0) {
		/* WSABUF has {ULONG len, CHAR *buf}. Build a small stack array. */
		WSABUF wsa[64];
		int i, n = iovcnt < 64 ? iovcnt : 64;
		for (i = 0; i < n; i++) {
			wsa[i].len = (ULONG)iov[i].iov_len;
			wsa[i].buf = (CHAR *)iov[i].iov_base;
		}
		if (WSASend((SOCKET)fd, wsa, n, &sent, 0, NULL, NULL) != 0)
			return -1;
		return (ssize_t)sent;
	}

	/* Non-socket path: emulate writev with repeated _write for file fds. */
	int i;
	size_t total = 0;
	for (i = 0; i < iovcnt; i++) {
		const char *p = (const char *)iov[i].iov_base;
		size_t remain = iov[i].iov_len;
		while (remain > 0) {
			/* _write() takes unsigned int length, split big buffers. */
			const unsigned max_write_chunk = (unsigned)INT_MAX;
			unsigned chunk = remain > max_write_chunk ?
						 max_write_chunk :
						 (unsigned)remain;
			int n = _write((int)fd, p, chunk);
			if (n < 0)
				return total > 0 ? (ssize_t)total : -1;
			if (n == 0)
				return (ssize_t)total;
			total += (size_t)n;
			p += n;
			remain -= (size_t)n;
		}
	}
	return (ssize_t)total;
}

#define open_fd_count() 0
#define libc_malloc_usable_size(ptr) ((void)ptr, 0)

int translate_socket_errno(int err);
void nonblock(fd_t fd);
int pipe(fd_t socks[2]);
int pipe_read(SOCKET sock, void *buf, size_t len);
int pipe_write(SOCKET sock, void *buf, size_t len);

static inline void fd_open_limit(int *soft, int *hard)
{
	*soft = 0;
	*hard = 0;
}

static inline void cpu_usage(float *stime, float *utime)
{
	*stime = 0;
	*utime = 0;
}

static inline int cpu_count(void)
{
	SYSTEM_INFO sysinfo;
	GetSystemInfo(&sysinfo);
	return sysinfo.dwNumberOfProcessors;
}

/* Signal handling stubs (not supported on Windows) */
static inline void signal_ignore_pipe(void) {}
static inline void signal_block_usr2(void) {}
static inline void signal_register_usr2(void (*handler)(int)) { (void)handler; }
static inline void signal_kill_usr2(void *tid) { (void)tid; }
void set_eh(void (*handler)(void));

/* DNS system configuration defaults (synthesized at runtime) */
struct lua_State;
int dns_push_resolvconf(struct lua_State *L);
int dns_push_hosts(struct lua_State *L);

#endif
