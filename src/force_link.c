#include <zlib.h>

void (*_dummy_deflate)(void) = (void *)deflate;
void (*_dummy_deflateEnd)(void) = (void *)deflateEnd;
void (*_dummy_inflate)(void) = (void *)inflate;
void (*_dummy_inflateEnd)(void) = (void *)inflateEnd;
