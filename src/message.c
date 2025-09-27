#include <stdatomic.h>
#include "message.h"

static atomic_int_least32_t type_id = MESSAGE_CUSTOM;

int message_register(const char *name)
{
	(void)name;
	//TODO: map the name and message id
	return atomic_fetch_add_explicit(&type_id, 1, memory_order_relaxed);
}
