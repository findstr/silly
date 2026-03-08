#ifndef _SILLY_WIN_H
#define _SILLY_WIN_H

#include <winsock2.h>
#include <ws2tcpip.h>
#include <iphlpapi.h>
#include <ws2def.h>
#include "log.h"

typedef intptr_t fd_t;

/* iovec / writev emulation via WSASend */
struct iovec {
	void *iov_base;
	size_t iov_len;
};

static inline ssize_t writev(fd_t fd, const struct iovec *iov, int iovcnt)
{
	DWORD sent = 0;
	/* WSABUF has {ULONG len, CHAR *buf} — same layout as iovec on
	 * little-endian Windows if we repack. Build a small stack array. */
	WSABUF wsa[64];
	int i, n = iovcnt < 64 ? iovcnt : 64;
	for (i = 0; i < n; i++) {
		wsa[i].len = (ULONG)iov[i].iov_len;
		wsa[i].buf = (CHAR *)iov[i].iov_base;
	}
	int ret = WSASend((SOCKET)fd, wsa, n, &sent, 0, NULL, NULL);
	if (ret != 0)
		return -1;
	return (ssize_t)sent;
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

/* DNS system configuration defaults (synthesized at runtime) */
struct lua_State;
int dns_push_resolvconf(struct lua_State *L);
int dns_push_hosts(struct lua_State *L);

#endif