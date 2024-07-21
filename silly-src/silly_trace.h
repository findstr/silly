#ifndef _SILLY_TRACE_H
#define _SILLY_TRACE_H

#include <stdint.h>

typedef uint16_t silly_tracespan_t;
typedef uint64_t silly_traceid_t;

void silly_trace_init();
void silly_trace_span(silly_tracespan_t id);
silly_traceid_t silly_trace_set(silly_traceid_t id);
silly_traceid_t silly_trace_get();
silly_traceid_t silly_trace_new();
silly_traceid_t silly_trace_propagate();

#endif
