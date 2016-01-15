#ifndef _ZPROTO_H
#define _ZPROTO_H

#include <stdint.h>

#define ZPROTO_INTEGER  1
#define ZPROTO_STRING   2
#define ZPROTO_RECORD   3
#define ZPROTO_TYPE     (0xffff)
#define ZPROTO_ARRAY    (1 << 16)

struct zproto;
struct zproto_record;
struct zproto_buffer;

struct zproto_field {
        int                     tag;
        int                     type;
        const char              *name;
        struct zproto_record    *seminfo;
        struct zproto_field     *next;
};

struct zproto *zproto_create();
void zproto_free(struct zproto *z);

int zproto_load(struct zproto *z, const char *path);
int zproto_parse(struct zproto *z, const char *data);
struct zproto_record *zproto_query(struct zproto *z, const char *name);

struct zproto_field *zproto_field(struct zproto *z, struct zproto_record *proto);

void zproto_buffer_drop(struct zproto_buffer *zb);
void zproto_buffer_fill(struct zproto_buffer *zb, int32_t pos, int32_t val);

//encode
struct zproto_buffer *zproto_encode_begin(struct zproto *z, int32_t protocol);
const uint8_t *zproto_encode_end(struct zproto_buffer *zb, int *sz);
int32_t zproto_encode_record(struct zproto_buffer *zb);
void zproto_encode_tag(struct zproto_buffer *zb, struct zproto_field *last, struct zproto_field *field, int32_t count);
void zproto_encode(struct zproto_buffer *zb, struct zproto_field *last, struct zproto_field *field, const char *data, int32_t sz);

//decode
int32_t zproto_decode_protocol(uint8_t *buffer, int sz);
struct zproto_buffer *zproto_decode_begin(struct zproto *z, const uint8_t *buff, int sz);
void zproto_decode_end(struct zproto_buffer *zb);
int32_t zproto_decode_record(struct zproto_buffer *zb);
struct zproto_field *zproto_decode_tag(struct zproto_buffer *zb, struct zproto_field *last, struct zproto_record *proto, int32_t *sz);
int zproto_decode(struct zproto_buffer *zb, struct zproto_field *field, uint8_t **data, int32_t *sz);

//pack
const uint8_t *zproto_pack(struct zproto *z, const uint8_t *src, int sz, int *osz);
const uint8_t *zproto_unpack(struct zproto *z, const uint8_t *src, int sz, int *osz);

void zproto_dump(struct zproto *z);

#endif

