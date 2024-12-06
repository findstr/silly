#include "silly.h"
#include "atomic.h"
#include "compiler.h"
#include "silly_log.h"
#include "silly_worker.h"
#include "silly_monitor.h"

struct monitor {
	uint32_t check_id;
} M;

void silly_monitor_init()
{
	M.check_id = 0;
}

void silly_monitor_check()
{
	uint32_t check_id = silly_worker_processid();
	if (unlikely(M.check_id == check_id)) {
		silly_worker_warnendless();
	}
	M.check_id = check_id;
}
