#ifndef _SOCKET_POLL_H
#define _SOCKET_POLL_H

#if defined(__linux__)

#include "socket_epoll.h"

#elif (defined(__macosx__))

#include "socket_kevent.h"

#endif


#endif

