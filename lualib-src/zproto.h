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

struct zproto_buffer *zproto_encode_begin(int32_t protocol);
char *zproto_encode_end(struct zproto_buffer *zb, int *sz);
int32_t zproto_encode_record(struct zproto_buffer *zb);
void zproto_encode_tag(struct zproto_buffer *zb, struct zproto_field *last, struct zproto_field *field, int32_t count);
void zproto_encode(struct zproto_buffer *zb, struct zproto_field *last, struct zproto_field *field, const char *data, int32_t sz);

int32_t zproto_decode_protocol(char *buffer, int sz);
struct zproto_buffer *zproto_decode_begin(char *buff, int sz);
void zproto_decode_end(struct zproto_buffer *zb);
int32_t zproto_decode_record(struct zproto_buffer *zb);
struct zproto_field *zproto_decode_tag(struct zproto_buffer *zb, struct zproto_field *last, struct zproto_record *proto, int32_t *sz);
int zproto_decode(struct zproto_buffer *zb, struct zproto_field *field, char **data, int32_t *sz);


void zproto_dump(struct zproto *z);

#endif

