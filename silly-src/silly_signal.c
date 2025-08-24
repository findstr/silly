#include <signal.h>
#include <string.h>
#include <errno.h>
#include <assert.h>

#include "compiler.h"
#include "silly.h"
#include "message.h"
#include "silly_worker.h"
#include "silly_log.h"

#include "silly_signal.h"

static int sigbits = 0;
static int MSG_TYPE_SIGNAL = 0;

struct message_signal {
	struct silly_message hdr;
	int signum;
};

static int signal_unpack(lua_State *L, struct silly_message *m)
{
	struct message_signal *ms = container_of(m, struct message_signal, hdr);
	lua_pushinteger(L, ms->signum);
	return 1;
}

static void signal_handler(int sig)
{
	struct message_signal *ms;
	ms = silly_malloc(sizeof(*ms));
	ms->hdr.type = MSG_TYPE_SIGNAL;
	ms->hdr.unpack = signal_unpack;
	ms->hdr.free = silly_free;
	ms->signum = sig;
	silly_worker_push(&ms->hdr);
}

int silly_signal_msgtype()
{
	assert(MSG_TYPE_SIGNAL != 0);  // ensure silly_signal_init has been called
	return MSG_TYPE_SIGNAL;
}

int silly_signal_init()
{
#ifndef __WIN32
	signal(SIGPIPE, SIG_IGN);
#endif
	MSG_TYPE_SIGNAL = message_new_type();
	return 0;
}

int silly_signal_watch(int signum)
{
	if ((sigbits & (1 << signum)) != 0) {
		return 0;
	}
	if (signal(signum, signal_handler) == SIG_ERR) {
		silly_log_error("signal %d ignore fail:%s\n", signum,
				strerror(errno));
		return errno;
	}
	sigbits |= 1 << signum;
	return 0;
}
