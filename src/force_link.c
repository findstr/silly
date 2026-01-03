#include <zlib.h>
#include <lz4.h>
#ifdef USE_SNAPPY
#include <snappy-c.h>
#endif

void (*_dummy_deflate)(void) = (void *)deflate;
void (*_dummy_deflateEnd)(void) = (void *)deflateEnd;
void (*_dummy_inflate)(void) = (void *)inflate;
void (*_dummy_inflateEnd)(void) = (void *)inflateEnd;

void (*_dummy_LZ4_compressBound)(void) = (void *)LZ4_compressBound;
void (*_dummy_LZ4_compress_default)(void) = (void *)LZ4_compress_default;
void (*_dummy_LZ4_decompress_safe)(void) = (void *)LZ4_decompress_safe;

#ifdef USE_SNAPPY
void (*_dummy_snappy_compress)(void) = (void *)snappy_compress;
void (*_dummy_snappy_uncompress)(void) = (void *)snappy_uncompress;
void (*_dummy_snappy_max_compressed_length)(void) = (void *)snappy_max_compressed_length;
void (*_dummy_snappy_uncompressed_length)(void) = (void *)snappy_uncompressed_length;
#endif
