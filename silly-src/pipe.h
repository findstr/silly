#ifndef _PIPE_H
#define _PIPE_H

#if defined(__linux__) || defined(__MACH__)
#define pipe_read(fd, buf, sz) read(fd, buf, sz)
#define pipe_write(fd, buf, sz) write(fd, buf, sz)
#endif

#if defined(__WIN32)

#include "event_iocp.h"

int pipe(fd_t socks[2]);
int pipe_read(SOCKET sock, void *buf, size_t len);
int pipe_write(SOCKET sock, void *buf, size_t len);

#endif

#endif
