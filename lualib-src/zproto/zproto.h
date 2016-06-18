#ifndef _ZPROTO_H
#define _ZPROTO_H

#include <stdint.h>

#define ZPROTO_BOOLEAN  1
#define ZPROTO_INTEGER  2
#define ZPROTO_STRING   3
#define ZPROTO_RECORD   4
#define ZPROTO_TYPE     (0xffff)
#define ZPROTO_ARRAY    (1 << 16)

struct zproto;
struct zproto_record;
struct zproto_field;
struct zproto_buffer;

struct zproto_field_iter {
        struct zproto_field *p;
        struct zproto_field *reserve;
};

struct zproto *zproto_create();
void zproto_free(struct zproto *z);

int zproto_load(struct zproto *z, const char *path);
int zproto_parse(struct zproto *z, const char *data);

struct zproto_record *zproto_query(struct zproto *z, const char *name);
struct zproto_record *zproto_querytag(struct zproto *z, uint32_t tag);

//record
uint32_t zproto_tag(struct zproto_record *proto);

//field
int zproto_field_type(struct zproto_field *field);
const char *zproto_field_name(struct zproto_field *field);
struct zproto_record *zproto_field_seminfo(struct zproto_field *field);

//iterator
void zproto_field_begin(struct zproto_record *proto, struct zproto_field_iter *iter);
void zproto_field_next(struct zproto_field_iter *iter);
int zproto_field_end(struct zproto_field_iter *iter);

//encode
struct zproto_buffer *zproto_encode_begin(struct zproto *z);
const uint8_t *zproto_encode_end(struct zproto_buffer *zb, int *sz);

size_t zproto_encode_record(struct zproto_buffer *zb);
void zproto_encode_recordnr(struct zproto_buffer *zb, size_t pos, int32_t val);

void zproto_encode_array(struct zproto_buffer *zb, struct zproto_field_iter *iter, int32_t count);
void zproto_encode(struct zproto_buffer *zb, struct zproto_field_iter *iter, const char *data, int32_t sz);

//decode
struct zproto_buffer *zproto_decode_begin(struct zproto *z, const uint8_t *buff, int sz);
size_t zproto_decode_end(struct zproto_buffer *zb);

int32_t zproto_decode_record(struct zproto_buffer *zb, struct zproto_field_iter *iter);

int zproto_decode_field(struct zproto_buffer *zb, struct zproto_record *proto, struct zproto_field_iter *iter, int32_t *sz);
int zproto_decode(struct zproto_buffer *zb, struct zproto_field_iter *iter, uint8_t **data, int32_t *sz);

//pack
const uint8_t *zproto_pack(struct zproto *z, const uint8_t *src, int sz, int *osz);
const uint8_t *zproto_unpack(struct zproto *z, const uint8_t *src, int sz, int *osz);

void zproto_dump(struct zproto *z);

#endif

