#ifndef _TRACE_H
#define _TRACE_H

#include "silly.h"

void trace_init();
void trace_set_node(silly_tracenode_t id);
silly_traceid_t trace_exchange(silly_traceid_t id);
silly_traceid_t trace_current();
silly_traceid_t trace_new();

#endif
