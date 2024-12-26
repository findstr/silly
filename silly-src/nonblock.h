#ifndef _NONBLOCK_H
#define _NONBLOCK_H

#ifndef __WIN32
static inline void nonblock(fd_t fd)
{
	int err;
	int flag;
	flag = fcntl(fd, F_GETFL, 0);
	if (unlikely(flag < 0)) {
		silly_log_error("[socket] nonblock F_GETFL:%s\n",
				strerror(errno));
		return;
	}
	flag |= O_NONBLOCK;
	err = fcntl(fd, F_SETFL, flag);
	if (unlikely(err < 0)) {
		silly_log_error("[socket] nonblock F_SETFL:%s\n",
				strerror(errno));
		return;
	}
	return;
}
#else
static inline void nonblock(fd_t fd)
{
	u_long mode = 1;
	if (ioctlsocket(fd, FIONBIO, &mode) != 0) {
		char buffer[512];
		FormatMessage(FORMAT_MESSAGE_FROM_SYSTEM |
				      FORMAT_MESSAGE_IGNORE_INSERTS,
			      NULL, WSAGetLastError(),
			      MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT), buffer,
			      sizeof(buffer), NULL);
		silly_log_error("[socket] nonblock fd:%d error:%s\n", fd,
				buffer);
	}
}
#endif

#endif