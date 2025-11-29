#include <unistd.h>
#include <sys/types.h>
#include <stdatomic.h>
#include "silly.h"
#include "compiler.h"

#include "timer.h"
#include "trace.h"

static silly_tracenode_t nodeid;
static atomic_uint_least16_t seq_idx = 0;

// traceid format:
// high 48bit: [16b root_nodeid | 16b time | 16b seq] is the immutable trace id
// low  16bit: parent_nodeid, updated at each hop
static THREAD_LOCAL silly_traceid_t trace_ctx = 0;

void trace_init()
{
}

void trace_set_node(silly_tracenode_t id)
{
	nodeid = id;
}

silly_traceid_t trace_exchange(silly_traceid_t id)
{
	silly_traceid_t old = trace_ctx;
	trace_ctx = id;
	return old;
}

silly_traceid_t trace_current()
{
	return trace_ctx;
}

silly_traceid_t trace_new()
{
	// root call, use dynamically calculated shifts
	const int SPAN_BITS = sizeof(silly_tracenode_t) * 8;
	const int TIME_BITS = sizeof(uint16_t) * 8;
	const int SEQ_BITS = sizeof(uint16_t) * 8;

	const int TIME_SHIFT = SPAN_BITS;
	const int SEQ_SHIFT = TIME_SHIFT + TIME_BITS;
	const int ROOT_ID_SHIFT = SEQ_SHIFT + SEQ_BITS;

	uint16_t time = (uint16_t)(timer_now() / 1000);
	uint16_t seq =
		atomic_fetch_add_explicit(&seq_idx, 1, memory_order_relaxed) +
		1;
	silly_traceid_t id = (silly_traceid_t)nodeid << ROOT_ID_SHIFT |
			     (silly_traceid_t)time << SEQ_SHIFT |
			     (silly_traceid_t)seq << TIME_SHIFT ;
	return id;
}
