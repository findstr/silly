#ifndef _MESSAGE_H_
#define _MESSAGE_H_

#include <lua.h>
#include "compiler.h"

enum message_type {
	MESSAGE_TIMER_EXPIRE,
	MESSAGE_SIGNAL_FIRE,
	MESSAGE_SOCKET_LISTEN,
	MESSAGE_SOCKET_CONNECT,
	MESSAGE_TCP_ACCEPT,
	MESSAGE_TCP_DATA,
	MESSAGE_UDP_DATA,
	MESSAGE_SOCKET_CLOSE,
	MESSAGE_CUSTOM,
};

int message_register(const char *name);

#endif