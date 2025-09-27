#include <signal.h>
#include <string.h>
#include <errno.h>
#include <assert.h>

#include "silly.h"
#include "mem.h"
#include "compiler.h"
#include "message.h"
#include "worker.h"
#include "log.h"

#include "sig.h"

static int sigbits = 0;

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
	ms = mem_alloc(sizeof(*ms));
	ms->hdr.type = MESSAGE_SIGNAL_FIRE;
	ms->hdr.unpack = signal_unpack;
	ms->hdr.free = mem_free;
	ms->signum = sig;
	worker_push(&ms->hdr);
}

int sig_init()
{
#ifndef __WIN32
	signal(SIGPIPE, SIG_IGN);
#endif
	return 0;
}

int sig_watch(int signum)
{
	if ((sigbits & (1 << signum)) != 0) {
		return 0;
	}
	if (signal(signum, signal_handler) == SIG_ERR) {
		log_error("signal %d ignore fail:%s\n", signum,
			  strerror(errno));
		return errno;
	}
	sigbits |= 1 << signum;
	return 0;
}
