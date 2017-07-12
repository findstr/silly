#ifndef _ZPROTO_H
#define _ZPROTO_H

#include <stdint.h>

#define ZPROTO_BOOLEAN (1)
#define ZPROTO_INTEGER (2)
#define ZPROTO_FLOAT (3)
#define ZPROTO_STRING (4)
#define ZPROTO_STRUCT (5)

#define ZPROTO_OOM (-1)
#define ZPROTO_NOFIELD (-2)
#define ZPROTO_ERROR (-3)

struct zproto;
struct zproto_struct;

//ENCODE: if 'len' is -1, the array nonexist
//	otherwise 'len' is length of array
//DECODE: the len is the length of array,
//it may be 0 when the array is empty
struct zproto_args {
	int tag;
	int type;
	int idx; //array index
	int len; //array length
	void *ud;
	int maptag;
	const char *name;
	const char *mapname; //for map
	uint8_t *buff;
	int buffsz;
	struct zproto_struct *sttype;
};

typedef int (*zproto_cb_t)(struct zproto_args *args);

struct zproto *zproto_create();
void zproto_free(struct zproto *z);

int zproto_load(struct zproto *z, const char *path);
int zproto_parse(struct zproto *z, const char *data);

struct zproto_struct *zproto_query(struct zproto *z, const char *name);
struct zproto_struct *zproto_querytag(struct zproto *z, int tag);
int zproto_tag(struct zproto_struct *st);
const char *zproto_name(struct zproto_struct *st);

//travel
struct zproto_struct *zproto_next(struct zproto *z, struct zproto_struct *st);

void zproto_travel(struct zproto_struct *st, zproto_cb_t cb, void *ud);

int zproto_encode(struct zproto_struct *st, uint8_t *buff, int sz, zproto_cb_t cb, void *ud);
int zproto_decode(struct zproto_struct *st, const uint8_t *buff, int sz, zproto_cb_t cb, void *ud);

//pack
int zproto_pack(const uint8_t *src, int srcsz, uint8_t *dst, int dstsz);
int zproto_unpack(const uint8_t *src, int srcsz, uint8_t *dst, int dstsz);

//for debug
void zproto_dump(struct zproto *z);

#endif

