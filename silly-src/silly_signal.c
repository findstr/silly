#include <signal.h>
#include <string.h>
#include <errno.h>
#include "compiler.h"

#include "silly.h"
#include "silly_worker.h"
#include "silly_log.h"

#include "silly_signal.h"

static int sigbits = 0;

static void signal_handler(int sig)
{
	struct silly_message_signal *ms;
	ms = silly_malloc(sizeof(*ms));
	ms->type = SILLY_SIGNAL;
	ms->signum = sig;
	silly_worker_push(tocommon(ms));
}

int silly_signal_init()
{
#ifndef __WIN32
	signal(SIGPIPE, SIG_IGN);
#endif
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
