#include <assert.h>
#include <ctype.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <sys/stat.h>
#include <setjmp.h>
#include "zproto.h"

#define ZPROTO_TYPE (0xffff)
#define ZPROTO_ARRAY (1 << 16)

#define CHUNK_SIZE (512)
#define ZBUFFER_SIZE (512)
#define TRY(z) if (setjmp(z->exception) == 0)
#define THROW(z) longjmp(z->exception, 1)

typedef uint16_t hdr_t;
typedef uint32_t len_t;

struct pool_chunk {
	size_t start;
	size_t last;
	struct pool_chunk *next;
};

struct zproto_field {
	int tag;
	int type;
	const char *name;
	struct zproto_struct *seminfo;
	struct zproto_field *mapkey;
	struct zproto_field *next;
};

struct zproto_struct {
	int tag;
	int basetag;
	int maxtag;
	int fieldnr;
	const char *name;
	struct zproto_struct *next;
	struct zproto_struct *parent;
	struct zproto_struct *child;
	struct zproto_field *field;
	struct zproto_field **fieldarray;
};

struct zproto {
	int linenr;
	const char *data;
	jmp_buf exception;
	struct pool_chunk *now;
	struct pool_chunk chunk;
	struct zproto_struct record;
};


static void *
pool_alloc(struct zproto *z, size_t sz)
{
	struct pool_chunk *c = z->now;
	assert(c->next == NULL);
	sz = (sz + 7) & (~7);	//align to 8 for performance
	if (c->last < sz) {
		void *p;
		struct pool_chunk *new;
		int need = (sz > CHUNK_SIZE) ? sz : CHUNK_SIZE;
		need = ((need - 1) / CHUNK_SIZE + 1) * CHUNK_SIZE;
		need -= sizeof(*new);
		new = (struct pool_chunk *)malloc(need + sizeof(*new));
		new->next = NULL;
		new->start = sz;
		new->last = need - sz;
		c->next = new;
		z->now = new;
		p = (void *)(new + 1);
		return p;
	} else {
		char *p = (char *)(c + 1);
		p = &p[c->start];
		c->last -= sz;
		c->start += sz;
		return (void *)p;
	}
}

static char *
pool_dupstr(struct zproto *z, char *str)
{
	int sz = strlen(str);
	char *new = (char *)pool_alloc(z, sz + 1);
	memcpy(new, str, sz);
	new[sz] = 0;

	return new;
}

static void
pool_free(struct zproto *z)
{
	struct pool_chunk *c = z->chunk.next;
	while (c) {
		struct pool_chunk *tmp = c;
		c = c->next;
		free(tmp);
	}
	z->chunk.next = NULL;
}

static int
eos(struct zproto *z)
{
	if (*(z->data) == 0)
		return 1;
	else
		return 0;
}

static void skip_space(struct zproto *z);

static void
next_line(struct zproto *z)
{
	const char *n = z->data;
	while (*n != '\n' && *n)
		n++;
	if (*n == '\n')
		n++;
	z->linenr++;
	z->data = n;
	skip_space(z);

	return ;
}

static void
skip_space(struct zproto *z)
{
	const char *n = z->data;
	while (isspace(*n) && *n) {
		if (*n == '\n')
			z->linenr++;
		n++;
	}

	z->data = n;
	if (*n == '#' && *n)
		next_line(z);

	return ;
}

static void
next_token(struct zproto *z)
{
	const char *n;
	skip_space(z);
	n = z->data;
	while (!isspace(*n) && *n)
		n++;
	z->data = n;
	skip_space(z);

	return ;
}

static struct zproto_struct *
find_record(struct zproto *z, struct zproto_struct *proto, const char *name)
{
	struct zproto_struct *tmp;
	if (proto == NULL)
		return NULL;

	for (tmp = proto->child; tmp; tmp = tmp->next) {
		if (strcmp(tmp->name, name) == 0)
			return tmp;
	}

	return find_record(z, proto->parent, name);
}

static struct zproto_field *
find_field(struct zproto *z, struct zproto_struct *proto, const char *name)
{
	struct zproto_field *tmp;
	(void)z;
	for (tmp = proto->field; tmp; tmp = tmp->next) {
		if (strcmp(tmp->name, name) == 0)
			return tmp;
	}
	return NULL;
}

static void
unique_record(struct zproto *z, struct zproto_struct *proto, const char *name)
{
	struct zproto_struct *tmp;
	for (tmp = proto->child; tmp; tmp = tmp->next) {
		if (strcmp(tmp->name, name) == 0) {
			fprintf(stderr, "line:%d syntax error:has already define a record named:%s\n", z->linenr, name);
			THROW(z);
		}
	}

	return;
}

static void
unique_field(struct zproto *z, struct zproto_struct *proto, const char *name, int tag)
{
	struct zproto_field *tmp;
	if (tag <= 0) {
		fprintf(stderr, "line:%d syntax error: tag must great then 0\n", z->linenr);
		THROW(z);
	}
	if (tag > 65535) {
		fprintf(stderr, "line:%d syntax error: tag must less then 655535\n", z->linenr);
		THROW(z);
	}
	for (tmp = proto->field; tmp; tmp = tmp->next) {
		if (strcmp(tmp->name, name) == 0) {
			fprintf(stderr, "line:%d syntax error:has already define a field named:%s\n", z->linenr, name);
			THROW(z);
		}

		if (tmp->tag == tag) {
			fprintf(stderr, "line:%d syntax error:tag %d has already defined\n", z->linenr, tag);
			THROW(z);
		}
	}

	return ;
}

static int
strtotype(struct zproto *z, struct zproto_struct *proto, const char *type, struct zproto_struct **seminfo, char mapkey[64])
{
	int ztype = 0;
	int sz = strlen(type);
	int mapidx = -1;
	*seminfo = NULL;
	mapkey[0] = 0;
	if (type[sz-1] == ']') {//array
		int i;
		int len;
		for (i = sz - 2; i >= 0; i--) {
			if (type[i] == '[') {
				mapidx = i + 1;
				break;
			}
		}
		if (i < 0) {
			fprintf(stderr, "line:%d syntax error:match none '['\n", z->linenr);
			THROW(z);
		}
		ztype |= ZPROTO_ARRAY;
		len = sz - 1 - mapidx;
		sz = i;
		assert(len < 63 && len >= 0);
		strncpy(mapkey, &type[mapidx], len);
		mapkey[len] = 0;
	}
	if (strncmp(type, "boolean", sz) == 0) {
		ztype |= ZPROTO_BOOLEAN;
	} else if (strncmp(type, "integer", sz) == 0) {
		ztype |= ZPROTO_INTEGER;
	} else if (strncmp(type, "long", sz) == 0) {
		ztype |= ZPROTO_LONG;
	} else if (strncmp(type, "float", sz) == 0) {
		ztype |= ZPROTO_FLOAT;
	} else if (strncmp(type, "string", sz) == 0) {
		ztype |= ZPROTO_STRING;
	} else {
		char cook[sz + 1];
		memcpy(cook, type, sz);
		cook[sz] = '\0';
		*seminfo = find_record(z, proto, cook);
		if (*seminfo == NULL) {
			fprintf(stderr, "line:%d syntax error:find no record name:%s\n", z->linenr, type);
			THROW(z);
		}
		ztype |= ZPROTO_STRUCT;
	}
	return ztype;
}

static void
merge_field(struct zproto *z, struct zproto_struct *proto)
{
	int i;
	struct zproto_field *f;
	proto->fieldnr = 0;
	if (proto->maxtag == 0)
		return ;
	f = proto->field;
	proto->basetag = f->tag;
	while (f) {
		assert(proto->maxtag >= f->tag);
		assert(f->tag >= proto->basetag);
		proto->fieldnr++;
		f = f->next;
	}
	proto->fieldarray = (struct zproto_field **)pool_alloc(z, proto->fieldnr * sizeof(*f));
	memset(proto->fieldarray, 0, sizeof(*f) * proto->fieldnr);
	i = 0;
	f = proto->field;
	while (f) {
		assert(i < proto->fieldnr);
		proto->fieldarray[i++] = f;
		f = f->next;
	}
	return ;
}

static void
reverse_field(struct zproto *z, struct zproto_struct *proto)
{
	(void)z;
	struct zproto_field *f = proto->field;
	proto->field = NULL;
	while (f) {
		struct zproto_field *tmp = f;
		f = f->next;
		tmp->next = proto->field;
		proto->field = tmp;
	}

	return ;
}

static void
field(struct zproto *z, struct zproto_struct *proto)
{
	int tag;
	int n;
	char field[64];
	char type[64];
	char mapkey[64];
	struct zproto_field *f;
	struct zproto_field *key;
	skip_space(z);
	const char *fmt = ".%64[a-zA-Z0-9_]:%64[]a-zA-Z0-9\[_]%*[' '|'\t']%d";
	n = sscanf(z->data, fmt, field, type, &tag);
	if (n != 3) {
		fmt = "line:%d synax error: expect field definition, but found:%s\n";
		fprintf(stderr, fmt, z->linenr, z->data);
		THROW(z);
	}
	unique_field(z, proto, field, tag);
	if (proto->field && tag <= proto->field->tag) {
		fmt = "line:%d synax error: tag value must be defined ascending\n";
		fprintf(stderr, fmt, z->linenr);
		THROW(z);
	}
	proto->maxtag = tag;
	f = (struct zproto_field *)pool_alloc(z, sizeof(*f));
	f->mapkey = NULL;
	f->next = proto->field;
	proto->field = f;
	f->tag = tag;
	f->name = pool_dupstr(z, field);
	f->type = strtotype(z, proto, type, &f->seminfo, mapkey);
	if (mapkey[0] == '\0')
		return;
	//map index can only be struct array
	assert(f->type & ZPROTO_ARRAY);
	if ((f->type & ZPROTO_TYPE) != ZPROTO_STRUCT) {
		fmt = "line:%d synax error: only struct array can be specify map index\n";
		fprintf(stderr, fmt, z->linenr);
		THROW(z);
	}
	key = find_field(z, f->seminfo, mapkey);
	if (key == NULL) {
		fmt = "line:%d synax error: struct %s has no field:%s\n";
		fprintf(stderr, fmt, z->linenr, f->seminfo->name, mapkey);
		THROW(z);
	}
	if (key->seminfo) {
		fmt = "line:%d synax error: struct type field '%s' can't be mapkey\n";
		fprintf(stderr, fmt, z->linenr, key->name);
		THROW(z);
	}
	if (key->type & ZPROTO_ARRAY) {
		fmt = "line:%d synax error: array field '%s' can't be mapkey\n";
		fprintf(stderr, fmt, z->linenr, f->name);
		THROW(z);
	}
	f->mapkey = key;
	return ;
}

static void
record(struct zproto *z, struct zproto_struct *proto, int protocol)
{
	int err;
	int tag = 0;
	char name[64];
	const char *fmt;
	struct zproto_struct *new;
	skip_space(z);
	if (eos(z))
		return;
	new = (struct zproto_struct *)pool_alloc(z, sizeof(*new));
	memset(new, 0, sizeof(*new));
	new->next = proto->child;
	new->parent = proto;
	if (protocol == 0) {
		err = sscanf(z->data, "%64s", name);
	} else {
		char buff[64];
		buff[0] = 0;
		err = sscanf(z->data, "%64s %32[0-9A-Za-zxX]", name, buff);
		tag = strtoul(buff, NULL, 0);
	}
	if (err < 1) {
		fmt = "line:%d syntax error: expect 'record name' [tag]\n";
		fprintf(stderr, fmt, z->linenr);
		THROW(z);
	}
	unique_record(z, proto, name);
	new->name = pool_dupstr(z, name);
	new->tag = tag;
	next_token(z);
	if (err == 2)
		next_token(z);

	if (*z->data != '{') {
		fmt = "line:%d syntax error: expect '{', but found:%s\n";
		fprintf(stderr, fmt, z->linenr, z->data);
		THROW(z);
	}

	next_token(z);

	while (*z->data != '.' && *z->data != '}') {	//child record
		record(z, new, 0);
		skip_space(z);
	}

	while (*z->data == '.') {
		field(z, new);
		next_line(z);
	}
	if (*z->data != '}') {
		fmt = "line:%d syntax error: expect '}', but found:%s\n";
		fprintf(stderr, fmt, z->linenr, z->data);
		THROW(z);
	}
	next_token(z);
	reverse_field(z, new);
	merge_field(z, new);
	proto->child = new;

	return ;
}

int
zproto_parse(struct zproto *z, const char *data)
{
	z->data = data;
	TRY(z) {
		do {
			record(z, &z->record, 1);
		} while (eos(z) == 0);

		return 0;
	}
	pool_free(z);
	return -1;
}


int
zproto_load(struct zproto *z, const char *path)
{
	int err;
	char *buff;
	struct stat st;
	err = stat(path, &st);
	if (err == -1) {
		perror("zproto_load:");
		return -1;
	}
	FILE *fp = fopen(path, "rb");
	if (fp == NULL) {
		perror("zproto_load:");
		return -1;
	}

	buff = (char *)malloc(st.st_size + 1);
	err = fread(buff, 1, st.st_size, fp);
	if (err != st.st_size) {
		perror("zproto_load:");
		err = -1;
		goto end;
	}
	buff[st.st_size] = '\0';
	err = zproto_parse(z, buff);
end:
	if (fp)
		fclose(fp);
	if (buff)
		free(buff);

	return err;

}

struct zproto_struct *
zproto_query(struct zproto *z, const char *name)
{
	struct zproto_struct *r;
	for (r = z->record.child; r; r = r->next) {
		if (strcmp(r->name, name) == 0)
			return r;
	}

	return NULL;
}

struct zproto_struct *
zproto_querytag(struct zproto *z, int tag)
{
	struct zproto_struct *r;
	for (r = z->record.child; r; r = r->next) {
		if (r->tag == tag)
			return r;
	}
	return NULL;
}

int
zproto_tag(struct zproto_struct *st)
{
	return st->tag;
}

const char *
zproto_name(struct zproto_struct *st)
{
	return st->name;
}


struct zproto_struct *
zproto_next(struct zproto *z, struct zproto_struct *st)
{
	if (st == NULL)
		st = z->record.child;
	else
		st = st->next;
	return st;
}

static inline void
fill_args(struct zproto_args *args, struct zproto_field *f, void *ud)
{
	args->tag = f->tag;
	args->name = f->name;
	args->type = f->type & ZPROTO_TYPE;
	args->sttype = f->seminfo;
	args->idx = -1;
	args->len = -1;
	args->ud = ud;
	if (f->mapkey) {
		args->maptag = f->mapkey->tag;
		args->mapname = f->mapkey->name;
	} else {
		args->maptag = 0;
		args->mapname = NULL;
	}
	return;
}

void
zproto_travel(struct zproto_struct *st, zproto_cb_t cb, void *ud)
{
	int i;
	for (i = 0; i < st->fieldnr; i++) {
		struct zproto_field *f;
		struct zproto_args args;
		f = st->fieldarray[i];
		fill_args(&args, f, ud);
		if (f->type & ZPROTO_ARRAY)
			args.idx = 0;
		cb(&args);
	}
}

static struct zproto_field *
queryfield(struct zproto_struct *st, int tag)
{
	int start = 0;
	int end = st->fieldnr;
	if (tag < st->basetag || tag > st->maxtag)
		return NULL;
	if ((st->maxtag - st->basetag + 1) == st->fieldnr) {
		int i = tag - st->basetag;
		assert(st->fieldarray[i]->tag == tag);
		return st->fieldarray[i];
	}
	while (start < end) {
		int mid = (start + end) / 2;
		if (tag == st->fieldarray[mid]->tag)
			return st->fieldarray[mid];
		if (tag < st->fieldarray[mid]->tag)
			end = mid;
		else
			start = mid + 1;
	}
	return NULL;
}

#define CHECK_OOM(sz, need)    \
	if (sz < (int)(need))\
		return ZPROTO_OOM;

static int
encode_field(struct zproto_args *args, zproto_cb_t cb)
{
	int sz;
	len_t *len;
	switch (args->type) {
	case ZPROTO_BOOLEAN:
		CHECK_OOM(args->buffsz, sizeof(uint8_t))
		return cb(args);
	case ZPROTO_INTEGER:
	case ZPROTO_FLOAT:
		CHECK_OOM(args->buffsz, sizeof(int32_t))
		return cb(args);
	case ZPROTO_LONG:
		CHECK_OOM(args->buffsz, sizeof(int64_t));
		return cb(args);
	case ZPROTO_STRING:
		CHECK_OOM(args->buffsz, sizeof(len_t))
		len = (len_t *)args->buff;
		args->buff += sizeof(len_t);
		args->buffsz -= sizeof(len_t);
		sz = cb(args);
		if (sz < 0)
			return sz;
		*len = sz;
		sz += sizeof(len_t);
		return sz;
	case ZPROTO_STRUCT:
		CHECK_OOM(args->buffsz, sizeof(hdr_t))
		return cb(args);
	default:
		assert(!"unkown field type");
		break;
	}
	return ZPROTO_ERROR;
}

static int
encode_array(struct zproto_args *args, zproto_cb_t cb)
{
	int err;
	len_t *len;
	int buffsz = args->buffsz;
	uint8_t *buff = args->buff;
	uint8_t *start = buff;

	CHECK_OOM(buffsz, sizeof(len_t))
	len = (len_t *)buff;
	buff += sizeof(len_t);
	buffsz -= sizeof(len_t);
	args->idx = 0;
	for (;;) {
		args->buffsz = buffsz;
		args->buff = buff;
		err = encode_field(args, cb);
		if (err < 0)
			break;
		buff += err;
		buffsz -= err;
		args->idx++;
	}
	if (err == ZPROTO_OOM)
		return err;
	if (args->len == -1)	//if len is negtive, the array field nonexist
		return ZPROTO_NOFIELD;
	*len = args->idx;
	return buff - start;
}


int
zproto_encode(struct zproto_struct *st, uint8_t *buff, int sz, zproto_cb_t cb, void *ud)
{
	int i;
	int err;
	len_t *total;
	hdr_t *len;
	hdr_t *tag;
	uint8_t *body;
	int last = st->basetag - 1; //tag now
	int fcnt = st->fieldnr; //field count
	int hdrsz= (fcnt + 1) * sizeof(hdr_t) + sizeof(len_t);

	CHECK_OOM(sz, hdrsz);
	total = (len_t *)buff;
	len = (hdr_t *)(total + 1);
	tag = len + 1;
	buff += hdrsz;
	sz -= hdrsz;
	body = buff;
	for (i = 0; i < fcnt; i++) {
		struct zproto_field *f;
		struct zproto_args args;
		f = st->fieldarray[i];
		fill_args(&args, f, ud);
		args.buff = buff;
		args.buffsz = sz;
		if (f->type & ZPROTO_ARRAY)
			err = encode_array(&args, cb);
		else
			err = encode_field(&args, cb);
		switch (err) {
		case ZPROTO_OOM:
			return err;
		case ZPROTO_NOFIELD:
			continue;
		default:
			assert(err > 0);
			break;
		}
		assert(sz >= err);
		buff += err;
		sz -= err;
		assert(f->tag >= last + 1);
		*tag = (f->tag - last - 1);
		tag++;
		last = f->tag;
	}
	*len = (tag - len) - 1; //length used one byte
	if ((uintptr_t)tag != (uintptr_t)body)
		memmove(tag, body, buff - body);
	*total = (buff - body) + ((uint8_t *)tag - (uint8_t *)len);
	return sizeof(len_t) + *total;
}



#define CHECK_VALID(sz, need)	\
	if (sz < (int)(need))\
		return ZPROTO_ERROR;

static int
decode_field(struct zproto_args *args, zproto_cb_t cb)
{
	int sz;
	len_t len;
	switch (args->type) {
	case ZPROTO_BOOLEAN:
		CHECK_VALID(args->buffsz, sizeof(uint8_t))
		args->buffsz = sizeof(uint8_t);
		return cb(args);
	case ZPROTO_INTEGER:
	case ZPROTO_FLOAT:
		CHECK_VALID(args->buffsz, sizeof(int32_t))
		args->buffsz = sizeof(int32_t);
		return cb(args);
	case ZPROTO_LONG:
		CHECK_VALID(args->buffsz, sizeof(int64_t))
		args->buffsz = sizeof(int64_t);
		return cb(args);
	case ZPROTO_STRING:
		CHECK_VALID(args->buffsz, sizeof(len_t))
		len = *(len_t *)args->buff;
		args->buff += sizeof(len_t);
		args->buffsz -= sizeof(len_t);
		CHECK_VALID(args->buffsz, len)
		args->buffsz = len;
		sz = cb(args);
		if (sz < 0)
			return sz;
		sz += sizeof(len_t);
		return sz;
	case ZPROTO_STRUCT:
		CHECK_VALID(args->buffsz, sizeof(hdr_t))
		return cb(args);
	default:
		assert(!"unkown field type");
		break;
	}
	return ZPROTO_ERROR;
}

static int
decode_array(struct zproto_args *args, zproto_cb_t cb)
{
	int i;
	int err;
	int len;
	uint8_t *buff;
	uint8_t *start;
	int buffsz;
	CHECK_VALID(args->buffsz, sizeof(len_t))
	start = args->buff;
	len = *(len_t *)args->buff;
	buff = args->buff + sizeof(len_t);
	buffsz = args->buffsz - sizeof(len_t);
	args->idx = 0;
	args->len = len;
	if (len == 0) { //empty array
		args->buff = NULL;
		err = cb(args);
		if (err < 0)
			return err;
	} else {
		for (i = 0; i < len; i++) {
			args->buff = buff;
			args->buffsz = buffsz;
			err = decode_field(args, cb);
			if (err < 0)
				return err;
			assert(err > 0);
			buff += err;
			buffsz -= err;
			args->idx++;
		}
	}
	return buff - start;
}

int
zproto_decode(struct zproto_struct *st, const uint8_t *buff, int sz, zproto_cb_t cb, void *ud)
{
	int i;
	int err;
	int last;
	len_t total;
	hdr_t len;
	hdr_t *tag;
	int	hdrsz;

	CHECK_VALID(sz, sizeof(hdr_t) + sizeof(len_t))    //header size
	last = st->basetag - 1; //tag now
	total = *(len_t *)buff;
	buff += sizeof(len_t);
	sz -= sizeof(len_t);
	CHECK_VALID(sz, total)
	sz = total;
	len = *(hdr_t *)buff;
	buff += sizeof(hdr_t);
	sz -=  sizeof(hdr_t);
	hdrsz = len * sizeof(hdr_t);
	CHECK_VALID(sz, hdrsz)
	tag = (hdr_t *)buff;
	buff += hdrsz;
	sz -= hdrsz;

	for (i = 0; i < len; i++) {
		struct zproto_field *f;
		struct zproto_args args;
		int t = *tag + last + 1;
		f = queryfield(st, t);
		if (f == NULL)
			break;
		fill_args(&args, f, ud);
		args.buff = (uint8_t *)buff;
		args.buffsz = sz;
		if (f->type & ZPROTO_ARRAY)
			err = decode_array(&args, cb);
		else
			err = decode_field(&args, cb);
		if (err < 0)
			return err;
		assert(err > 0);
		buff += err;
		sz -= err;
		tag++;
		last = t;
	}
	return total + sizeof(len_t);
}

//////////encode/decode
//////////pack
static int
packseg(const uint8_t *src, int sn, uint8_t *dst, int dn)
{
	int i;
	int pack_sz = 0;
	uint8_t *hdr = dst++;
	--dn;
	assert(dn >= 0);
	*hdr = 0;
	sn = sn < 8 ? sn : 8;
	for (i = 0; i < sn; i++) {
		if (src[i]) {
			*hdr |= 1 << i;
			*dst++ = src[i];
			++pack_sz;
			--dn;
		}
	}
	assert(dn >= 0);
	return pack_sz;
}

static int
packff(const uint8_t *src, int sn, uint8_t *dst, int dn)
{
	int i;
	int packsz = 0;
	sn = sn < 8 ? sn : 8;
	for (i = 0; i < sn; i++) {
		if (src[i])
			++packsz;
	}
	if (packsz >= 6) {	//6, 7, 8
		assert(dn >= sn);
		memcpy(dst, src, sn);
		packsz = sn;
	}
	return packsz;
}


static int
pack(const uint8_t *src, int sn, uint8_t *dst, int dn)
{
	int packsz;
	uint8_t *ffn = NULL;
	uint8_t *dstart = dst;
	int needn = ((sn + 2047) / 2048) * 2 + sn;
	if (sn % 8 != 0)
		++needn;

	if (needn > dn)
		return -1;

	packsz = -1;
	while (sn > 0) {
		if (packsz != 8) {  //pack segment
			packsz = packseg(src, sn, dst, dn);
			src += 8;
			sn -= 8;
			dst += packsz + 1;	//skip the data+header
			dn -= packsz + 1;
			if (packsz == 8 && sn > 0) {   //it's 0xff
				ffn = dst;
				++dst;
				--dn;
			} else {
				ffn = NULL;
			}
		} else if (packsz == 8) {
			*ffn = 0;
			for (;;) {
				packsz = packff(src, sn, dst, dn);
				if (packsz == 6 || packsz == 7 || packsz == 8) {
					src += 8;
					sn -= 8;
					dst += packsz;
					dn -= packsz;
					++(*ffn);
					if (*ffn == 255) {
						ffn = NULL;
						packsz = -1;
						break;
					}
				} else {
					break;
				}
			}
		}
	}
	return dst - dstart;
}

static int
unpackseg(const uint8_t *src, int sn, uint8_t *dst, int dn)
{
	uint8_t hdr;
	const uint8_t *end;
	int unpacksz = 0;
	sn = sn < 9 ? sn : 9;//header + data
	if (dn < 8)
		return ZPROTO_OOM;
	end = src + sn;
	hdr = *src++;
	if (hdr == 0) {
		memset(dst, 0, 8);
	} else {
		int i;
		for (i = 0; i < 8; i++) {
			if (hdr & 0x01 && src != end) { //defend invalid data
				*dst++ = *src++;
				unpacksz++;
			} else {
				*dst++ = 0;
			}
			hdr >>= 1;
		}
	}
	return unpacksz;
}

static int
unpackff(const uint8_t *src, int sn, uint8_t *dst, int dn)
{
	if (dn < 8)
		return -ZPROTO_OOM;
	sn = sn < 8 ? sn : 8;
	memcpy(dst, src, sn);
	memset(&dst[sn], 0, 8 - sn);
	return sn;
}

static int
unpack(const uint8_t *src, int sn, uint8_t *dst, int dn)
{
	int unpacksz = -1;
	int ffn = -1;
	uint8_t *dstart = dst;
	while (sn > 0) {
		if (unpacksz != 8) {
			unpacksz = unpackseg(src, sn, dst, dn);
			if (unpacksz < 0)    //not enough storage space
				return unpacksz;

			src += unpacksz + 1;
			sn -= unpacksz + 1;
			dst += 8;
			dn -= 8;
			if (unpacksz == 8 && sn > 0) {
				ffn = *src;
				++src;
				--sn;
			}
		} else if (unpacksz == 8) {
			int i;
			int n;
			//ffn - 1, because the last ff pack size may 6, 7, 8
			if ((ffn - 1) * 8 > sn)
				return ZPROTO_ERROR;
			for (i = 0; i < ffn; i++) {
				n = unpackff(src, sn, dst, dn);
				if (n < 0)
					return n;
				src += n;
				sn -= n;
				dst += 8;
				dn -= 8;
			}
			unpacksz = -1; //restart unpack
		}
	}
	return dst - dstart;
}

int
zproto_pack(const uint8_t *src, int srcsz, uint8_t *dst, int dstsz)
{
	int n;
	int needn = ((srcsz + 2047) / 2048) * 2 + srcsz;
	if (srcsz % 8 != 0)
		++needn;
	if (dstsz < needn)
		return ZPROTO_OOM;
	n = pack(src, srcsz, dst, dstsz);
	assert(n > 0);
	return n;
}

int
zproto_unpack(const uint8_t *src, int srcsz, uint8_t *dst, int dstsz)
{
	return unpack(src, srcsz, dst, dstsz);
}

struct zproto *
zproto_create()
{
	struct zproto *z = (struct zproto *)malloc(sizeof(*z));
	memset(z, 0, sizeof(*z));
	z->now = &z->chunk;

	return z;
}

void
zproto_free(struct zproto *z)
{
	pool_free(z);
	free(z);
	return ;
}

//for debug

static void
dump_record(struct zproto_struct *proto)
{
	struct zproto_struct *tr;
	struct zproto_field *tf;
	if (proto == NULL)
		return ;

	printf("=====record:%s\n", proto->name);
	printf("-----field:\n");
	for (tf = proto->field; tf; tf = tf->next) {
		if (tf->type & ZPROTO_ARRAY)
			printf("array:");
		if ((tf->type & ZPROTO_TYPE) == ZPROTO_STRUCT)
			printf("%s:%s-%d\n", tf->name, tf->seminfo->name, tf->tag);
		else
			printf("%s:%d-%d\n", tf->name, tf->type & ZPROTO_TYPE, tf->tag);
	}

	printf("==========child record\n");
	dump_record(proto->child);
	if (proto->next == NULL)
		return ;

	printf("----brother---\n");
	for (tr = proto->next; tr; tr = tr->next)
		dump_record(tr);
	printf("----brother end---\n");

}


void
zproto_dump(struct zproto *z)
{
	struct zproto_struct *r = z->record.child;
	dump_record(r);
}


