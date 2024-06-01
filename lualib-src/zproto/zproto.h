#ifndef _ZPROTO_H
#define _ZPROTO_H

#include <stdint.h>
#include <setjmp.h>

enum {
	ZPROTO_BOOLEAN,
	ZPROTO_BYTE,
	ZPROTO_UBYTE,
	ZPROTO_SHORT,
	ZPROTO_USHORT,
	ZPROTO_INTEGER,
	ZPROTO_UINTEGER,
	ZPROTO_LONG,
	ZPROTO_ULONG,
	ZPROTO_FLOAT,
	ZPROTO_STRING,
	ZPROTO_BLOB,
	ZPROTO_STRUCT,
};

#define ZPROTO_OOM (-1)
#define ZPROTO_NOFIELD (-2)
#define ZPROTO_ERROR (-3)

struct zproto;

struct zproto_field {
	short tag;
	unsigned char type;
	unsigned char isarray;
	const char *name;
	struct zproto_struct *seminfo;
	struct zproto_field *mapkey;
};

struct zproto_struct {
	int tag;
	int basetag;
	int iscontinue;
	int fieldcount;
	const char *name;
	struct zproto_starray *child;
	struct zproto_field **fields;
};

struct zproto_starray {
	int count;
	struct zproto_struct *buf[1];
};

struct zproto_parser {
	char error[256];
	struct zproto *z;
};

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

int zproto_load(struct zproto_parser *p, const char *path);
int zproto_parse(struct zproto_parser *p, const char *data);
void zproto_free(struct zproto *z);

struct zproto_struct *zproto_query(struct zproto *z, const char *name);
struct zproto_struct *zproto_querytag(struct zproto *z, int tag);
int zproto_tag(struct zproto_struct *st);
const char *zproto_name(struct zproto_struct *st);

//travel
const struct zproto_starray *zproto_root(struct zproto *z);
const char *zproto_typename(int type);


int zproto_encode(struct zproto_struct *st, uint8_t *buff, int sz, zproto_cb_t cb, void *ud);
int zproto_decode(struct zproto_struct *st, const uint8_t *buff, int sz, zproto_cb_t cb, void *ud);

//pack
int zproto_pack(const uint8_t *src, int srcsz, uint8_t *dst, int dstsz);
int zproto_unpack(const uint8_t *src, int srcsz, uint8_t *dst, int dstsz);

//for debug
void zproto_dump(struct zproto *z);

#endif

