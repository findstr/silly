#ifndef _SOCKET_POLL_H
#define _SOCKET_POLL_H

#if defined(__linux__)

#include "socket_epoll.h"
#define SOCKET_POLL_API "epoll"
#elif (defined(__macosx__))

#include "socket_kevent.h"
#define SOCKET_POLL_API "kevent"

#else

#include "socket_select.h"
#define SOCKET_POLL_API "select"

#endif


#endif

