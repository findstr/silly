#include "silly.h"
#include "compiler.h"
#include "log.h"
#include "worker.h"
#include "monitor.h"

struct monitor {
	uint32_t check_id;
} M;

void monitor_init()
{
	M.check_id = 0;
}

void monitor_check()
{
	uint32_t check_id = worker_process_id();
	if (unlikely(M.check_id == check_id)) {
		worker_warn_endless();
	}
	M.check_id = check_id;
}
