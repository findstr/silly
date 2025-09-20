#ifndef _TRACE_H
#define _TRACE_H

#include "silly.h"

void trace_init();
void trace_span(silly_tracespan_t id);
silly_traceid_t trace_set(silly_traceid_t id);
silly_traceid_t trace_get();
silly_traceid_t trace_new();
silly_traceid_t trace_propagate();

#endif
