#ifndef _SILLY_UNIX_H
#define _SILLY_UNIX_H
#include <arpa/inet.h>
#include <unistd.h>
#include <netdb.h>
#include <netinet/tcp.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/resource.h>

#if defined(__linux__)
#include <sys/epoll.h>
#include <malloc.h>
size_t memory_rss_(void);
#define libc_malloc_usable_size(ptr) malloc_usable_size(ptr)
#define memory_rss() memory_rss_()
#elif defined(__MACH__)
#include <malloc/malloc.h>
#include <sys/event.h>
#include <sys/sysctl.h>
#define libc_malloc_usable_size(ptr) malloc_size(ptr)
#endif

#define translate_socket_errno(x) (x)
#define pipe_read(fd, buf, sz) read(fd, buf, sz)
#define pipe_write(fd, buf, sz) write(fd, buf, sz)

typedef int fd_t;
void nonblock(fd_t fd);
int open_fd_count(void);
void fd_open_limit(int *soft, int *hard);
void cpu_usage(float *stime, float *utime);
static inline int cpu_count(void)
{
#if defined(__MACH__)
	int count = 0;
	size_t len = sizeof(count);
	sysctlbyname("hw.ncpu", &count, &len, NULL, 0);
	return count;
#else
	return sysconf(_SC_NPROCESSORS_ONLN);
#endif
}

#endif
