#ifndef _SILLY_WIN_H
#define _SILLY_WIN_H

#include <winsock2.h>
#include <ws2tcpip.h>
#include <iphlpapi.h>
#include <ws2def.h>
#include "log.h"

#define open_fd_count() 0
#define libc_malloc_usable_size(ptr) ((void)ptr, 0)

typedef intptr_t fd_t;
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

#endif