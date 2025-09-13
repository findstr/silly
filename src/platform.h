#ifndef SILLY_PLATFORM_H
#define SILLY_PLATFORM_H

#if defined(__linux__) || defined(__MACH__)
#include "unix/unix.h"
#elif defined(__WIN32)
#include "win/win.h"
#else
#error "Unsupported platform"
#endif

#if defined(__linux__)

#include "unix/event_epoll.h"
#define SOCKET_POLL_API "epoll"
#endif

#if defined(__MACH__)

#include "unix/event_kevent.h"
#define SOCKET_POLL_API "kevent"

#endif

#if defined(__WIN32)

#include "win/event_iocp.h"
#define SOCKET_POLL_API "iocp"

#endif

#ifdef __WIN32
#define CONNECT_IN_PROGRESS EWOULDBLOCK
#undef errno
#define errno translate_socket_errno(WSAGetLastError())
#else
#define CONNECT_IN_PROGRESS EINPROGRESS
#define closesocket close
#endif

#ifdef __WIN32
#define random() rand()
#define localtime_r(t, tm) localtime_s(tm, t)
#endif

#endif