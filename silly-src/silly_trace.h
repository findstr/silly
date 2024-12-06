#ifndef _SILLY_TRACE_H
#define _SILLY_TRACE_H

#include <stdint.h>

typedef uint16_t silly_trace_span_t;
typedef uint64_t silly_trace_id_t;

void silly_trace_init();
void silly_trace_span(silly_trace_span_t id);
silly_trace_id_t silly_trace_set(silly_trace_id_t id);
silly_trace_id_t silly_trace_get();
silly_trace_id_t silly_trace_new();
silly_trace_id_t silly_trace_propagate();

#endif
