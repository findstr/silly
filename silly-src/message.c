#include <stdatomic.h>
#include "message.h"

static atomic_int_least32_t type_id = 1;

int message_new_type()
{
	return atomic_fetch_add_explicit(&type_id, 1, memory_order_relaxed);
}
