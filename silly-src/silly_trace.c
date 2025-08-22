#include <unistd.h>
#include <sys/types.h>
#include <stdatomic.h>
#include "silly.h"
#include "compiler.h"

#include "silly_timer.h"
#include "silly_trace.h"

static silly_tracespan_t spanid;
static atomic_uint_least16_t seq_idx = 0;
//63~48,         47~32,	     31~16,     15~0
//spanid(16bit),time(16bit),seq(16bit),spanid(16bit)
static THREAD_LOCAL silly_traceid_t trace_ctx = 0;

void silly_trace_init()
{
	silly_trace_span((silly_tracespan_t)getpid());
}

void silly_trace_span(silly_tracespan_t id)
{
	spanid = id;
}

silly_traceid_t silly_trace_set(silly_traceid_t id)
{
	silly_traceid_t old = trace_ctx;
	trace_ctx = id;
	return old;
}

silly_traceid_t silly_trace_get()
{
	return trace_ctx;
}

silly_traceid_t silly_trace_new()
{
	if (trace_ctx > 0) {
		return (trace_ctx & ~((silly_traceid_t)0xFF)) |
		       (uint64_t)spanid;
	}
	uint16_t time = (uint16_t)(silly_timer_now() / 1000);
	uint16_t seq = atomic_fetch_add_explicit(&seq_idx, 1, memory_order_relaxed) + 1;
	silly_traceid_t id = (uint64_t)spanid << 48 | (uint64_t)time << 32 |
			     (uint64_t)seq << 16 | (uint64_t)spanid;
	return id;
}
