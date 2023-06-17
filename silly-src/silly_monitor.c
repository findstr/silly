#include "silly.h"
#include "atomic.h"
#include "compiler.h"
#include "silly_log.h"
#include "silly_monitor.h"

struct monitor {
	unsigned int process_id;
	unsigned int check_id;
	int msgtype;
} M;

static const char *msgname[] = {
	"NIL",
	"EXPIRE",
	"ACCEPT",
	"CLOSE",
	"CONNECTED",
	"TCPDATA",
	"UDPDATA",
};

void
silly_monitor_init()
{
	M.process_id = 0;
	M.check_id = 0;
	M.msgtype = 0;
}

void
silly_monitor_check()
{
	if (M.msgtype != 0 && unlikely(M.check_id == M.process_id)) {
		silly_log_warn("[monitor] message of %s processed slowly\n",
			msgname[M.msgtype]);
	}
	M.check_id = M.process_id;
}

void
silly_monitor_trigger(int msgtype)
{
	M.msgtype = msgtype;
	atomic_add(&M.process_id, 1);
}


