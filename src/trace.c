#include <unistd.h>
#include <sys/types.h>
#include <stdatomic.h>
#include "silly.h"
#include "compiler.h"

#include "timer.h"
#include "trace.h"

static silly_tracespan_t spanid;
static atomic_uint_least16_t seq_idx = 0;

// traceid format:
// high 48bit: [16b root_nodeid | 16b time | 16b seq] is the immutable trace id
// low  16bit: parent_nodeid, updated at each hop
static THREAD_LOCAL silly_traceid_t trace_ctx = 0;

void trace_init()
{
	trace_span((silly_tracespan_t)getpid());
}

void trace_span(silly_tracespan_t id)
{
	spanid = id;
}

silly_traceid_t trace_set(silly_traceid_t id)
{
	silly_traceid_t old = trace_ctx;
	trace_ctx = id;
	return old;
}

silly_traceid_t trace_get()
{
	return trace_ctx;
}

silly_traceid_t trace_new()
{
	// child call, use type-safe MASK
	if (trace_ctx > 0) {
		const silly_traceid_t MASK = (silly_tracespan_t)-1;
		return (trace_ctx & ~MASK) | (silly_traceid_t)spanid;
	}

	// root call, use dynamically calculated shifts
	const int SPAN_BITS = sizeof(silly_tracespan_t) * 8;
	const int TIME_BITS = sizeof(uint16_t) * 8;
	const int SEQ_BITS = sizeof(uint16_t) * 8;

	const int TIME_SHIFT = SPAN_BITS;
	const int SEQ_SHIFT = TIME_SHIFT + TIME_BITS;
	const int ROOT_ID_SHIFT = SEQ_SHIFT + SEQ_BITS;

	uint16_t time = (uint16_t)(timer_now() / 1000);
	uint16_t seq =
		atomic_fetch_add_explicit(&seq_idx, 1, memory_order_relaxed) +
		1;

	silly_traceid_t id = (silly_traceid_t)spanid << ROOT_ID_SHIFT |
			     (silly_traceid_t)time << SEQ_SHIFT |
			     (silly_traceid_t)seq << TIME_SHIFT |
			     (silly_traceid_t)spanid;
	return id;
}
