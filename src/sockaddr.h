#ifndef _SOCKADDR_H
#define _SOCKADDR_H

#include "platform.h"

//replace 'sockaddr_storage' with this struct,
//because we only care about 'ipv6' and 'ipv4'
union sockaddr_full {
	struct sockaddr sa;
	struct sockaddr_in v4;
	struct sockaddr_in6 v6;
};

static inline size_t sockaddr_len(const union sockaddr_full *sa)
{
	if (sa == NULL)
		return 0;
	return (sa->sa.sa_family == AF_INET ? sizeof(struct sockaddr_in) : \
		sizeof(struct sockaddr_in6));
}

#endif