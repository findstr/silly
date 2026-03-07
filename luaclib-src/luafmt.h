#ifndef _LUAFMT_H
#define _LUAFMT_H

#include <stddef.h>
#include <stdint.h>
#include <limits.h>

/* Fast integer to string conversion.
 * Returns the length of the string.
 * buf must have at least 24 bytes for 64-bit integers.
 */
static inline int luafmt_int64(char *buf, int64_t n)
{
	char tmp[24];
	char *p = tmp + sizeof(tmp);
	uint64_t un;

	if (n == LLONG_MIN) {
		/* Special case: -9223372036854775808 */
		__builtin_memcpy(buf, "-9223372036854775808", 20);
		return 20;
	}

	if (n < 0) {
		un = (uint64_t)-n;
	} else {
		un = (uint64_t)n;
	}

	do {
		*--p = (char)('0' + (un % 10));
		un /= 10;
	} while (un);

	if (n < 0)
		*--p = '-';

	int len = (int)(tmp + sizeof(tmp) - p);
	__builtin_memcpy(buf, p, len);
	return len;
}

/* Unsigned version */
static inline int luafmt_uint64(char *buf, uint64_t n)
{
	char tmp[24];
	char *p = tmp + sizeof(tmp);

	do {
		*--p = (char)('0' + (n % 10));
		n /= 10;
	} while (n);

	int len = (int)(tmp + sizeof(tmp) - p);
	__builtin_memcpy(buf, p, len);
	return len;
}

#endif  /* _LUAFMT_H */
