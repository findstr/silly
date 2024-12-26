#ifndef _POLL_H
#define _POLL_H

#if defined(__linux__)

#include "event_epoll.h"
#define SOCKET_POLL_API "epoll"
#endif

#if defined(__MACH__)

#include "event_kevent.h"
#define SOCKET_POLL_API "kevent"

#endif

#if defined(__WIN32)

#include "event_iocp.h"
#define SOCKET_POLL_API "iocp"

#endif

#endif
