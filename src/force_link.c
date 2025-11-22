#include <zlib.h>
#include <snappy-c.h>

void (*_dummy_deflate)(void) = (void *)deflate;
void (*_dummy_deflateEnd)(void) = (void *)deflateEnd;
void (*_dummy_inflate)(void) = (void *)inflate;
void (*_dummy_inflateEnd)(void) = (void *)inflateEnd;

void (*_dummy_snappy_compress)(void) = (void *)snappy_compress;
void (*_dummy_snappy_uncompress)(void) = (void *)snappy_uncompress;
void (*_dummy_snappy_max_compressed_length)(void) = (void *)snappy_max_compressed_length;
void (*_dummy_snappy_uncompressed_length)(void) = (void *)snappy_uncompressed_length;
