#include "silly.h"
#include "compiler.h"
#include "log.h"
#include "worker.h"
#include "monitor.h"

#ifdef SILLY_TEST
#include <stdatomic.h>
#include <string.h>

static atomic_int monitor_pause = 0;

void monitor_debug_ctrl(const char *cmd, va_list ap) {
	(void)ap;
	if (strcmp(cmd, "pause") == 0) {
		atomic_store_explicit(&monitor_pause, 1, memory_order_relaxed);
	} else if (strcmp(cmd, "resume") == 0) {
		atomic_store_explicit(&monitor_pause, 0, memory_order_relaxed);
	}
}

int monitor_is_paused(void) {
	return atomic_load_explicit(&monitor_pause, memory_order_relaxed);
}
#endif

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
		worker_mark_endless();
	}
	M.check_id = check_id;
}
