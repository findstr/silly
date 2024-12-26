#ifndef _NET_H
#define _NET_H

#if defined(__linux__)
#include <sys/epoll.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <netdb.h>
#include <netinet/tcp.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/resource.h>
#define translate_socket_errno(x) (x)
#endif

#if defined(__MACH__)
#include <sys/event.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <netdb.h>
#include <netinet/tcp.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/resource.h>
#define translate_socket_errno(x) (x)
#endif

#if defined(__WIN32)
#include <winsock2.h>
#include <ws2tcpip.h>
#include <iphlpapi.h>
#include <ws2def.h>
#include "silly_log.h"

static inline int translate_socket_errno(int err)
{
	switch (err) {
	case 0:
		return 0;
	case WSAEINTR:
		return EINTR;
	case WSAEBADF:
		return EBADF;
	case WSAEACCES:
		return EACCES;
	case WSAEFAULT:
		return EFAULT;
	case WSAEINVAL:
		return EINVAL;
	case WSAEMFILE:
		return EMFILE;
	case WSAENOBUFS:
		return ENOBUFS;
	case WSAENOTSOCK:
		return ENOTSOCK;
	case WSAEOPNOTSUPP:
		return EOPNOTSUPP;
	case WSAEAFNOSUPPORT:
		return EAFNOSUPPORT;
	case WSAEADDRINUSE:
		return EADDRINUSE;
	case WSAEADDRNOTAVAIL:
		return EADDRNOTAVAIL;
	case WSAENETDOWN:
		return ENETDOWN;
	case WSAENETUNREACH:
		return ENETUNREACH;
	case WSAENETRESET:
		return ENETRESET;
	case WSAECONNABORTED:
		return ECONNABORTED;
	case WSAECONNRESET:
		return ECONNRESET;
	case WSAEISCONN:
		return EISCONN;
	case WSAENOTCONN:
		return ENOTCONN;
	case WSAETIMEDOUT:
		return ETIMEDOUT;
	case WSAECONNREFUSED:
		return ECONNREFUSED;
	case WSAENOTEMPTY:
		return ENOTEMPTY;
	case WSAEWOULDBLOCK:
		return EWOULDBLOCK;
	case WSAEINPROGRESS:
		return EINPROGRESS;
	case WSAEPROTONOSUPPORT:
		return EPROTONOSUPPORT;
	case WSAEALREADY:
		return EALREADY;
	default:
		silly_log_error("[net] unsupport translate_socket_errno:%d\n",
				err);
		return err;
	}
}

#endif

#endif
