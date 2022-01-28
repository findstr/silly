#include <assert.h>
#include <ctype.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <sys/stat.h>
#include "zproto.h"

#define ZPROTO_TYPE (0xffff)
#define ZPROTO_ARRAY (1 << 16)

#define ARRAYSIZE(n)	(sizeof(n)/sizeof((n)[0]))
#define TOKEN_SIZE	(64)
#define TOKEN_STRING	(1)
#define TOKEN_DIGIT	(2)

#define CHUNK_SIZE (512)
#define TRY(l) if (setjmp(l.exception) == 0)
#define THROW(l, ...) {\
	struct zproto_parser *p = l->p;\
	int n = (int)sizeof(p->error);\
	int r = snprintf(p->error, n, "line %d syntax error: ", l->line);\
	if (r > 0 && r < n) \
		snprintf(&p->error[r], n - r, __VA_ARGS__);\
	longjmp(l->exception, 1);\
}

struct zproto_field {
	int tag;
	int type;
	const char *name;
	struct zproto_struct *seminfo;
	struct zproto_field *mapkey;
};

struct starray {
	int count;
	struct zproto_struct *buf[1];
};

struct zproto_struct {
	int tag;
	int basetag;
	int iscontinue;
	int fieldcount;
	const char *name;
	struct starray *child;
	struct zproto_field **fields;
};

struct zproto {
	union chunk *chunk;
	struct starray *root;
	struct starray *namecache;
	struct starray *tagcache;
};

union alignment {
	void *p;
	int n;
};

union chunk {
	union alignment _;
	union chunk *next;
};

struct memory {
	int size;
	char *ptr;
	union chunk *chunk;
};

struct lexfieldbuf {
	int count;
	int capacity;
	struct zproto_field **fields;
};

struct lexstruct {
	int childn;
	struct zproto_struct *st;
	struct lexstruct *next;
	struct lexstruct *child;
	struct lexstruct *parent;
	struct lexstruct *allnext;
};

struct lexstate {
	int line;
	int maxtag;
	int structhastag;
	const char *data;
	jmp_buf exception;
	struct memory mem;
	struct lexfieldbuf buf;
	struct lexstruct *freestruct;
	struct lexstruct *allstruct;
	struct zproto_parser *p;
};

#define ALIGN_MASK	(sizeof(union alignment) - 1)

static void *
memory_alloc(struct memory *m, size_t sz)
{
	sz = (sz + ALIGN_MASK) & (~ALIGN_MASK); //align to 8 for performance
	if (m->size < (int)sz) {
		void *p;
		int need;
		union chunk *chunk;
		need = (sz + sizeof(*chunk));
		if (need > CHUNK_SIZE)
			need = ((need- 1) / CHUNK_SIZE + 1) * CHUNK_SIZE;
		else
			need = CHUNK_SIZE;
		chunk = (union chunk *)malloc(need);
		need -= sizeof(*chunk);
		chunk->next = m->chunk;
		m->chunk = chunk;
		m->size = need - sz;
		p = (void *)(chunk + 1);
		m->ptr = p + sz;
		return p;
	} else {
		char *ptr = m->ptr;
		m->size -= sz;
		m->ptr += sz;
		return ptr;
	}
}

static char *
memory_dupstr(struct memory *m, char *str)
{
	int sz = strlen(str);
	char *new = (char *)memory_alloc(m, sz + 1);
	memcpy(new, str, sz);
	new[sz] = 0;
	return new;
}

static void
memory_free(union chunk *c)
{
	union chunk *tmp;
	while (c) {
		tmp = c;
		c = c->next;
		free(tmp);
	}
}

static struct zproto *
zproto_create()
{
	struct zproto *z = (struct zproto *)malloc(sizeof(*z));
	memset(z, 0, sizeof(*z));
	return z;
}

void
zproto_free(struct zproto *z)
{
	memory_free(z->chunk);
	free(z);
	return ;
}

static void
lex_init(struct lexstate *l)
{
	struct lexfieldbuf *buf;
	memset(l, 0, sizeof(*l));
	l->line = 1;
	buf = &l->buf;
	buf->count = 0;
	buf->capacity = 64;
	buf->fields = malloc(buf->capacity * sizeof(struct zproto_field *));
	return ;
}

static void
lex_free(struct lexstate *l)
{
	//free struct node
	struct lexstruct *ptr = l->allstruct;
	while (ptr) {
		struct lexstruct *tmp = ptr;
		ptr = ptr->allnext;
		free(tmp);
	}
	free(l->buf.fields);
}

static void
lex_pushfield(struct lexstate *l, struct zproto_field *f)
{
	struct lexfieldbuf *buf = &l->buf;
	if (buf->count >= buf->capacity) {
		size_t newsz;
		buf->capacity *= 2;
		newsz = buf->capacity * sizeof(struct zproto_field *);
		buf->fields = realloc(buf->fields, newsz);
	}
	buf->fields[buf->count++] = f;
	return ;
}

static struct lexstruct *
lex_newstruct(struct lexstate *l)
{
	struct lexstruct *st;
	if (l->freestruct) {
		st = l->freestruct;
		l->freestruct = st->next;
	} else {
		st = (struct lexstruct *)malloc(sizeof(*st));
		st->allnext = l->allstruct;
		l->allstruct = st;
	}
	st->childn = 0;
	st->st = NULL;
	st->next = st->child = st->parent = NULL;
	return st;
}

static void
lex_freestruct(struct lexstate *l, struct lexstruct *st)
{
	st->next = l->freestruct;
	l->freestruct = st;
}

static struct starray *
lex_collapse(struct lexstate *l, int count, struct lexstruct *ptr)
{
	int i = 0;
	struct starray *arr;
	int size = sizeof(*arr) + (int)sizeof(arr->buf[0]) * (count - 1);
	arr = memory_alloc(&l->mem, size);
	while (ptr != NULL) {
		arr->buf[i++] = ptr->st;
		ptr = ptr->next;
	}
	assert(i == count);
	arr->count = i;
	return arr;
}

static struct starray *
lex_clonearray(struct lexstate *l, const struct starray *arr)
{
	struct starray *ptr;
	int size = sizeof(*arr) + (int)sizeof(arr->buf[0]) * (arr->count - 1);
	ptr = memory_alloc(&l->mem, size);
	memcpy(ptr, arr, size);
	return ptr;
}

static void
lex_mergefield(struct lexstate *l, struct zproto_struct *st)
{
	int i, count;
	struct lexfieldbuf *buf = &l->buf;
	count = buf->count;
	if (count == 0)
		return ;
	st->fieldcount = count;
	st->fields = memory_alloc(&l->mem, count * sizeof(st->fields[0]));
	memset(st->fields, 0, sizeof(st->fields[0]) * count);
	st->basetag = buf->fields[0]->tag;
	if ((l->maxtag - st->basetag + 1) == count) //continue tag define
		st->iscontinue = 1;
	for (i = 0; i < count; i++)
		st->fields[i] = buf->fields[i];
	//clear buffer
	buf->count = 0;
	return ;
}

static void lex_skipspace(struct lexstate *l);

static int
lex_eos(struct lexstate *l)
{
	return *l->data == 0 ? 1 : 0;
}

static void
lex_nextline(struct lexstate *l)
{
	const char *n = l->data;
	while (*n != '\n' && *n)
		n++;
	if (*n == '\n')
		n++;
	l->line++;
	l->data = n;
	lex_skipspace(l);
	return ;
}

static void
lex_skipspace(struct lexstate *l)
{
	const char *n = l->data;
	while (isspace(*n)) {
		if (*n == '\n')
			++l->line;
		n++;
	}
	l->data = n;
	if (*n == '#')
		lex_nextline(l);
	return ;
}

static void
lex_readlstring(struct lexstate *l, char *token, int tokensz)
{
	char *tokenend;
	const char *str;
	str = l->data;
	tokenend = &token[tokensz];
	while ((isalnum(*str) || *str == '_') && token < tokenend)
		*token++ = *str++;
	if (token == tokenend)
		THROW(l, "max length of token is '%d'\n", tokensz - 1);
	*token = '\0';
	l->data = str;
	return ;
}

static void
lex_readdigit(struct lexstate *l, char *token, int tokensz)
{
	int n;
	char *tokenend;
	const char *str;
	int (*is)(int c);
	str = l->data;
	if (tokensz < 4)	//'0x0\0'
		THROW(l, "internal error, token buffer too small\n");
	tokenend = &token[tokensz];
	n = *str++;
	*token++ = n;
	if (n == '0' && (str[0] == 'x' || str[0] == 'X')) {
		is = isxdigit;
		*token++ = *str++;
	} else {
		is = isdigit;
	}
	while (is(*str) && token < tokenend)
		*token++ = *str++;
	if (token == tokenend)
		THROW(l, "max length of number is '%d'\n", tokensz - 1);
	*token = '\0';
	l->data = str;
	return ;
}

static int
lex_lookahead(struct lexstate *l)
{
	int ch, type;
	lex_skipspace(l);
	ch = *l->data;
	switch (ch) {
	case '{':
	case '}':
	case '.':
	case ':':
	case '[':
	case ']':
	case '\0':
		type = ch;
		break;
	case '0': case '1': case '2': case '3': case '4':
	case '5': case '6': case '7': case '8': case '9':
		type = TOKEN_DIGIT;
		break;
	default: //name or string
		type = isalpha(ch) ? TOKEN_STRING : ch;
		break;
	}
	return type;
}

static void
lex_nexttoken(struct lexstate *l, int expect, char *token, int tokensz)
{
	char buff[TOKEN_SIZE];
	int type = lex_lookahead(l);
	if (type != expect) {
		token = buff;
		tokensz = ARRAYSIZE(buff);
	}
	switch (type) {
	case TOKEN_STRING:
		lex_readlstring(l, token, tokensz);
		break;
	case TOKEN_DIGIT:
		lex_readdigit(l, token, tokensz);
		break;
	case '\0':
		break;
	default:
		++l->data;
		break;
	}
	if (type != expect) {
		char extype[16];
		switch (expect) {
		case TOKEN_STRING:
			strcpy(extype, "string");
			break;
		case TOKEN_DIGIT:
			strcpy(extype, "digit");
			break;
		default:
			extype[0] = expect;
			extype[1] = 0;
			break;
		}
		switch (type) {
		case TOKEN_STRING:
		case TOKEN_DIGIT:
			THROW(l, "expect '%s', but found '%s'\n", extype, buff);
			break;
		case '\0':
			THROW(l, "expect '%s', at end of input\n", extype);
			break;
		default:
			THROW(l, "expect '%s' but found '%c'\n", extype, type);
			break;
		}
	}
	return ;
}

static struct zproto_struct *
lex_findstruct(struct lexstruct *node, const char *name)
{
	struct lexstruct *tmp;
	for (;;) {//recursive
		for (tmp = node->child; tmp; tmp = tmp->next) {
			if (strcmp(tmp->st->name, name) == 0)
				return tmp->st;
		}
		node = node->parent;
		if (node == NULL)
			return NULL;
	}
	return NULL;
}

static struct zproto_field *
lex_findfield(struct zproto_struct *st, const char *name)
{
	int i;
	struct zproto_field *f;
	for (i = 0; i < st->fieldcount; i++) {
		f = st->fields[i];
		if (strcmp(f->name, name) == 0)
			return f;
	}
	return NULL;
}

static void
lex_uniquestruct(struct lexstate *l, struct lexstruct *parent,
		const char *name, int tag)
{
	struct lexstruct *tmp;
	for (tmp = parent->child; tmp; tmp = tmp->next) {
		if (strcmp(tmp->st->name, name) == 0)
			THROW(l, "already define a struct '%s'\n", name);
		if (tmp->st->tag != 0 && tmp->st->tag == tag)
			THROW(l, "already define a protocol tag '%d'\n", tag);
	}
	return;
}

static void
lex_uniquefield(struct lexstate *l, const char *name, int tag)
{
	int i;
	struct lexfieldbuf *buf;
	if (tag <= 0)
		THROW(l, "tag must great then 0\n");
	if (tag > 65535)
		THROW(l, "tag must less then 655535\n");
	if (tag <= l->maxtag)
		THROW(l, "tag must be defined ascending\n");
	buf = &l->buf;
	for (i = 0; i < buf->count; i++) {
		struct zproto_field *f = buf->fields[i];
		if (strcmp(f->name, name) == 0)
			THROW(l, "already define a field '%s'\n", name);
	}
	return ;
}

static int
lex_typeint(struct lexstate *l, struct lexstruct *node,
	const char *type, struct zproto_struct **seminfo)
{
	size_t i;
	static struct {
		const char *name;
		int type;
	} types[] = {
		{"integer", ZPROTO_INTEGER},
		{"uinteger", ZPROTO_UINTEGER},
		{"long", ZPROTO_LONG},
		{"ulong", ZPROTO_ULONG},
		{"short", ZPROTO_SHORT},
		{"ushort", ZPROTO_USHORT},
		{"byte", ZPROTO_BYTE},
		{"ubyte", ZPROTO_UBYTE},
		{"string", ZPROTO_STRING},
		{"blob", ZPROTO_BLOB},
		{"boolean", ZPROTO_BOOLEAN},
		{"float", ZPROTO_FLOAT},
	};
	*seminfo = NULL;
	for (i = 0; i < sizeof(types)/sizeof(types[0]); i++) {
		if (strcmp(type, types[i].name) == 0)
			return types[i].type;
	}
	*seminfo = lex_findstruct(node, type);
	if (*seminfo == NULL)
		THROW(l, "nonexist struct '%s'\n", type);
	return ZPROTO_STRUCT;
}

#define NEXT_TOKEN(l, tk) lex_nexttoken(l, tk, NULL, 0)
#define NEXT_DIGIT(l, buf) lex_nexttoken(l, TOKEN_DIGIT, (buf), ARRAYSIZE(buf))
#define NEXT_STRING(l, buf) lex_nexttoken(l, TOKEN_STRING, (buf), ARRAYSIZE(buf))

static void
lex_field(struct lexstate *l, struct lexstruct *node)
{
	int tag, ahead;
	const char *fmt;
	char name[TOKEN_SIZE];
	char type[TOKEN_SIZE];
	char mapkey[TOKEN_SIZE];
	char strtag[TOKEN_SIZE];
	struct zproto_field *f;
	struct zproto_field *key;
	f = (struct zproto_field *)memory_alloc(&l->mem, sizeof(*f));
	//.field:integer 1
	NEXT_TOKEN(l, '.');
	//field name
	NEXT_STRING(l, name);
	NEXT_TOKEN(l, ':');
	//type name
	NEXT_STRING(l, type);
	f->type = lex_typeint(l, node, type, &f->seminfo);
	//[mapkey]
	ahead = lex_lookahead(l);
	if (ahead == '[') {	//is a array ?
		int type = f->type;
		NEXT_TOKEN(l, '[');
		f->type |= ZPROTO_ARRAY;
		ahead = lex_lookahead(l);
		if (ahead != ']') { //just only a map array ?
			NEXT_STRING(l, mapkey);
		} else {
			mapkey[0] = 0;
			if (type == ZPROTO_UBYTE) //ubyte[] is blob type
				f->type = ZPROTO_BLOB;
			else if (type == ZPROTO_BYTE) // byte[] is string byte
				f->type = ZPROTO_STRING;
		}
		NEXT_TOKEN(l, ']');
	} else {
		mapkey[0] = 0;
	}
	//tag
	NEXT_DIGIT(l, strtag);
	tag = strtoul(strtag, NULL, 0);
	lex_uniquefield(l, name, tag);
	l->maxtag = tag;
	lex_pushfield(l, f);
	f->mapkey = NULL;
	f->tag = tag;
	f->name = memory_dupstr(&l->mem, name);
	if (mapkey[0] == 0)
		return ;
	//map index can only be struct array
	if ((f->type & ZPROTO_TYPE) != ZPROTO_STRUCT)
		THROW(l, "only struct array can be specify map index\n");
	key = lex_findfield(f->seminfo, mapkey);
	if (key == NULL) {
		fmt = "struct %s has no field '%s'\n";
		THROW(l, fmt, f->seminfo->name, mapkey);
	}
	if (key->seminfo) {
		fmt = "struct field '%s' can't be mapkey\n";
		THROW(l, fmt, key->name);
	}
	if (key->type & ZPROTO_ARRAY) {
		fmt = "array field '%s' can't be mapkey\n";
		THROW(l, fmt, f->name);
	}
	f->mapkey = key;
	return ;
}

static struct lexstruct *
lex_struct(struct lexstate *l, struct lexstruct *parent, int protocol)
{
	int tag, ahead, count = 0;
	struct lexstruct *node;
	char name[TOKEN_SIZE];
	struct lexstruct **next;
	struct zproto_struct *newst;
	NEXT_STRING(l, name);
	if (protocol != 0 && lex_lookahead(l) == TOKEN_DIGIT) {
		char digit[TOKEN_SIZE];
		NEXT_DIGIT(l, digit);
		tag = strtoul(digit, NULL, 0);
		l->structhastag = 1;
	} else {
		tag = 0;
	}
	lex_uniquestruct(l, parent, name, tag);
	NEXT_TOKEN(l, '{');
	ahead = lex_lookahead(l);
	node = lex_newstruct(l);
	node->parent = parent;
	node->child = NULL;
	next = &node->child;
	while (ahead == TOKEN_STRING) { //child struct
		struct lexstruct *lst;
		lst = lex_struct(l, node, 0);
		if (lst == NULL)
			THROW(l, "broken struct '%s'\n", name);
		*next = lst;
		next = &lst->next;
		ahead = lex_lookahead(l);
		++count;
	}
	//delay create zproto_struct for more cache-friendly
	newst = (struct zproto_struct *)memory_alloc(&l->mem, sizeof(*newst));
	memset(newst, 0, sizeof(*newst));
	node->st = newst;
	newst->name = memory_dupstr(&l->mem, name);
	newst->tag = tag;
	newst->child = lex_collapse(l, count, node->child);
	assert(l->buf.count == 0);
	l->maxtag = 0;
	while (ahead == '.') {
		lex_field(l, node);
		ahead = lex_lookahead(l);
	}
	NEXT_TOKEN(l, '}');
	lex_mergefield(l, newst);
	lex_skipspace(l);
	if (node->child) {
		lex_freestruct(l, node->child);
		node->child = NULL;
	}
	return node;
}

static int
compn(const void *a, const void *b)
{
	struct zproto_struct **sta, **stb;
	sta = (struct zproto_struct **)a;
	stb = (struct zproto_struct **)b;
	return strcmp((*sta)->name, (*stb)->name);
}

static int
compt(const void *a, const void *b)
{
	int ta = (*(struct zproto_struct **)a)->tag;
	int tb = (*(struct zproto_struct **)b)->tag;
	if (ta < tb)
		return -1;
	if (ta > tb)
		return 1;
	return 0;
}

int
zproto_parse(struct zproto_parser *p, const char *data)
{
	struct zproto *z;
	struct lexstate l;
	struct lexstruct *lst;
	struct lexstruct **next;
	lex_init(&l);
	l.data = data;
	l.p = p;
	TRY(l) {
		int count = 0;
		struct starray *arr, *nc, *tc;
		struct lexstruct root;
		root.parent = NULL;
		root.child = NULL;
		next = &root.child;
		do {
			lst = lex_struct(&l, &root, 1);
			*next = lst;
			next = &lst->next;
			++count;
		} while (lex_eos(&l) == 0);
		arr = lex_collapse(&l, count, root.child);
		//create some cache
		nc = lex_clonearray(&l, arr);
		qsort(nc->buf, nc->count, sizeof(nc->buf[0]), compn);
		if (l.structhastag) {
			tc = lex_clonearray(&l, arr);
			qsort(tc->buf, tc->count, sizeof(tc->buf[0]), compt);
		} else {
			tc = NULL;
		}
		//all success, now create zproto
		p->z = z = zproto_create();
		z->root = arr;
		z->namecache = nc;
		z->tagcache = tc;
		z->chunk = l.mem.chunk;
		lex_free(&l);
		return 0;
	}
	p->z = NULL;
	memory_free(l.mem.chunk);
	lex_free(&l);
	return -1;
}


int
zproto_load(struct zproto_parser *p, const char *path)
{
	int err;
	char *buff;
	int file_size;
	FILE *fp = fopen(path, "rb");
	if (fp == NULL) {
		perror("zproto_load:");
		return -1;
	}
	fseek(fp, 0, SEEK_END);
	file_size = ftell(fp);
	fseek(fp, 0, SEEK_SET);
	buff = (char *)malloc(file_size + 1);
	err = fread(buff, 1, file_size, fp);
	if (err != file_size) {
		perror("zproto_load:");
		err = -1;
		goto end;
	}
	buff[file_size] = '\0';
	err = zproto_parse(p, buff);
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
	struct starray *root = z->namecache;
	int start = 0, end = root->count;
	while (start < end) {
		int mid = (start + end) / 2;
		struct zproto_struct *st = root->buf[mid];
		int ret = strcmp(name, st->name);
		if (ret < 0)
			end = mid;
		else if (ret > 0)
			start = mid + 1;
		else
			return st;
	}
	return NULL;
}

struct zproto_struct *
zproto_querytag(struct zproto *z, int tag)
{
	int start, end;
	struct starray *root = z->tagcache;
	if (root == NULL)
		return NULL;
	start = 0;
	end = root->count;
	while (start < end) {
		int mid = (start + end) / 2;
		struct zproto_struct *st = root->buf[mid];
		if (tag < st->tag)
			end = mid;
		else if (tag > st->tag)
			start = mid + 1;
		else
			return st;
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

struct zproto_struct *const*
zproto_child(struct zproto *z, struct zproto_struct *st, int *count)
{
	struct starray *child;
	child = st == NULL ? z->root : st->child;
	if (child) {
		*count = child->count;
		return child->buf;
	}
	*count = 0;
	return NULL;
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
	for (i = 0; i < st->fieldcount; i++) {
		struct zproto_field *f;
		struct zproto_args args;
		f = st->fields[i];
		fill_args(&args, f, ud);
		if (f->type & ZPROTO_ARRAY)
			args.idx = 0;
		cb(&args);
	}
}

static struct zproto_field *
queryfield(struct zproto_struct *st, int tag)
{
	int start, end;
	struct zproto_field **fields = st->fields;
	int fieldcount = st->fieldcount;
	if (st->iscontinue) {	//continue tag
		int i = tag - st->basetag;
		if (i < 0 || i >= fieldcount)
			return NULL;
		assert(fields[i]->tag == tag);
		return fields[i];
	}
	start = 0;
	end = fieldcount;
	while (start < end) {
		int mid = (start + end) / 2;
		if (tag == fields[mid]->tag)
			return fields[mid];
		if (tag < fields[mid]->tag)
			end = mid;
		else
			start = mid + 1;
	}
	return NULL;
}

static inline int
marshal_uint16(uint8_t *buff, uint32_t v)
{
	buff[0] = v & 0xff;
	buff[1] = (v >> 8) & 0xff;
	return 2;
}

static inline uint32_t
unmarshal_uint16(const uint8_t *buff)
{
	return (buff[0] | (buff[1] << 8));
}

static inline int
marshal_uint32(uint8_t *buff, uint32_t v)
{
	buff[0] = v & 0xff;
	buff[1] = (v >> 8) & 0xff;
	buff[2] = (v >> 16) & 0xff;
	buff[3] = (v >> 24) & 0xff;
	return 4;
}

static inline uint32_t
unmarshal_uint32(const uint8_t *buff)
{
	return (buff[0] | (buff[1] << 8) | (buff[2] << 16) | (buff[3] << 24));
}

static inline int
marshal_uint64(uint8_t *buff, uint64_t v)
{
	buff[0] = v & 0xff;
	buff[1] = (v >> 8) & 0xff;
	buff[2] = (v >> 16) & 0xff;
	buff[3] = (v >> 24) & 0xff;
	buff[4] = (v >> 32) & 0xff;
	buff[5] = (v >> 40) & 0xff;
	buff[6] = (v >> 48) & 0xff;
	buff[7] = (v >> 56) & 0xff;
	return 8;
}

static inline uint64_t
unmarshal_uint64(const uint8_t *buff)
{
	uint64_t v;
	v = unmarshal_uint32(buff + 4);
	v <<= 32;
	v |= unmarshal_uint32(buff);
	return v;
}


#define SIZEOF_TAG	2
#define SIZEOF_LEN	4

static inline int
marshal_tag(uint8_t *buff, uint32_t v)
{
	return marshal_uint16(buff, v);
}

static inline uint32_t
unmarshal_tag(const uint8_t *buff)
{
	return unmarshal_uint16(buff);
}

static inline int
marshal_len(uint8_t *buff, uint32_t v)
{
	return marshal_uint32(buff, v);
}

static inline uint32_t
unmarshal_len(const uint8_t *buff)
{
	return unmarshal_uint32(buff);
}

#define CHECK_OOM(sz, need)\
	if (sz < (int)(need))\
		return ZPROTO_OOM;

#define ENCODE_INTEGER(bit)\
	args->buff = (uint8_t *)&u.u##bit;\
	args->buffsz = sizeof(uint##bit##_t);\
	sz = cb(args);\
	if (sz < 0)\
		return sz;\
	return marshal_uint##bit(buff, u.u##bit);

static int
encode_field(struct zproto_args *args, zproto_cb_t cb)
{
	int sz;
	uint8_t *buff;
	union {
		uint16_t u16;
		uint32_t u32;
		uint64_t u64;
	} u;
	CHECK_OOM(args->buffsz, sizeof(uint64_t));
	buff = args->buff;
	switch(args->type) {
	case ZPROTO_BOOLEAN:
	case ZPROTO_BYTE:
	case ZPROTO_UBYTE:
		args->buffsz = sizeof(uint8_t);
		sz = cb(args);
		if (sz < 0)
			return sz;
		return sizeof(uint8_t);
	case ZPROTO_SHORT:
	case ZPROTO_USHORT:
		ENCODE_INTEGER(16)
	case ZPROTO_INTEGER:
	case ZPROTO_UINTEGER:
		ENCODE_INTEGER(32)
	case ZPROTO_LONG:
	case ZPROTO_ULONG:
		ENCODE_INTEGER(64)
	case ZPROTO_FLOAT:
		ENCODE_INTEGER(32)
	case ZPROTO_BLOB:
	case ZPROTO_STRING:
		CHECK_OOM(args->buffsz, SIZEOF_LEN);
		args->buff += SIZEOF_LEN;
		args->buffsz -= SIZEOF_LEN;
		sz = cb(args);
		if (sz < 0)
			return sz;
		marshal_len(buff, sz);
		return (SIZEOF_LEN + sz);
	case ZPROTO_STRUCT:
		return cb(args);
	}
	return ZPROTO_ERROR;
}

static int
encode_array(struct zproto_args *args, zproto_cb_t cb)
{
	int err;
	uint8_t *len, *buff;
	int buffsz = args->buffsz;
	CHECK_OOM(buffsz, SIZEOF_LEN);
	buff = args->buff;
	len = buff;
	buff += SIZEOF_LEN;
	buffsz -= SIZEOF_LEN;
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
	marshal_len(len, args->idx);
	return buff - len;
}


int
zproto_encode(struct zproto_struct *st, uint8_t *buff, int sz, zproto_cb_t cb, void *ud)
{
	uint32_t datasize;
	int i, err, lasttag;
	struct zproto_field **fields;
	uint8_t *len, *tagcount, *tag, *body;
	int fieldcount = st->fieldcount; //field count
	int hdrsz= SIZEOF_LEN + (fieldcount + 1) * SIZEOF_TAG;
	CHECK_OOM(sz, hdrsz);
	fields = st->fields;
	len = buff;
	tagcount = (len + SIZEOF_LEN);
	tag = tagcount + SIZEOF_TAG;
	buff += hdrsz;
	sz -= hdrsz;
	body = buff;
	lasttag = st->basetag - 1; //tag begin
	for (i = 0; i < fieldcount ; i++) {
		struct zproto_field *f;
		struct zproto_args args;
		f = fields[i];
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
		assert(f->tag >= lasttag + 1);
		marshal_tag(tag, f->tag - lasttag - 1);
		tag += SIZEOF_TAG;
		lasttag = f->tag;
	}
	//length used one slot
	marshal_tag(tagcount, (tag - tagcount) / SIZEOF_TAG - 1);
	if (tag != body)
		memmove(tag, body, buff - body);
	datasize = (tag - tagcount) + (buff - body);
	marshal_len(len, datasize);
	return SIZEOF_LEN + datasize;
}


#define CHECK_VALID(sz, need)	\
	if ((size_t)sz < (need))\
		return ZPROTO_ERROR;

#define DECODE_INTEGER(bit)\
	CHECK_VALID(args->buffsz, sizeof(uint##bit##_t))\
	u.u##bit= unmarshal_uint##bit(args->buff);\
	args->buff = (uint8_t *)&u.u##bit;\
	args->buffsz = sizeof(uint##bit##_t);\
	cb(args);\
	return sizeof(uint##bit##_t);

static int
decode_field(struct zproto_args *args, zproto_cb_t cb)
{
	uint32_t len;
	union {
		uint16_t u16;
		uint32_t u32;
		uint64_t u64;
	} u;
	switch(args->type) {
	case ZPROTO_BOOLEAN:
	case ZPROTO_BYTE:
	case ZPROTO_UBYTE:
		CHECK_VALID(args->buffsz, sizeof(uint8_t));
		args->buffsz = sizeof(uint8_t);
		cb(args);
		return sizeof(uint8_t);
	case ZPROTO_SHORT:
	case ZPROTO_USHORT:
		DECODE_INTEGER(16)
	case ZPROTO_INTEGER:
	case ZPROTO_UINTEGER:
		DECODE_INTEGER(32)
	case ZPROTO_LONG:
	case ZPROTO_ULONG:
		DECODE_INTEGER(64)
	case ZPROTO_FLOAT:
		DECODE_INTEGER(32)
	case ZPROTO_BLOB:
	case ZPROTO_STRING:
		CHECK_VALID(args->buffsz, SIZEOF_LEN);
		len = unmarshal_len(args->buff);
		args->buff += SIZEOF_LEN;
		args->buffsz -= SIZEOF_LEN;
		CHECK_VALID(args->buffsz, len)
		args->buffsz = len;
		cb(args);
		return SIZEOF_LEN + len;
	case ZPROTO_STRUCT:
		return cb(args);
	}
	return ZPROTO_ERROR;
}

static int
decode_array(struct zproto_args *args, zproto_cb_t cb)
{
	int err, i, len;
	uint8_t *start;
	uint8_t *buff = args->buff;
	int buffsz = args->buffsz;
	CHECK_VALID(buffsz, SIZEOF_LEN);
	start = buff;
	len = unmarshal_len(buff);
	buff += SIZEOF_LEN;
	buffsz -= SIZEOF_LEN;
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
zproto_decode(struct zproto_struct *st,
	const uint8_t *buff, int size,
	zproto_cb_t cb, void *ud)
{
	const uint8_t *tagptr;
	size_t len, headsize;
	int i, err, tagcount, lasttag;
	CHECK_VALID(size, SIZEOF_LEN + SIZEOF_TAG) //header size
	len = unmarshal_len(buff);
	buff += SIZEOF_LEN;
	size -= SIZEOF_LEN;
	CHECK_VALID(size, len)
	size = len;
	tagcount = unmarshal_tag(buff);
	buff += SIZEOF_TAG;
	size -= SIZEOF_TAG;
	headsize = SIZEOF_TAG * tagcount;
	CHECK_VALID(size, headsize)
	tagptr = buff;
	buff += headsize;
	size -= headsize;
	lasttag = st->basetag - 1; //tag now
	for (i = 0; i < tagcount; i++) {
		struct zproto_field *f;
		struct zproto_args args;
		int t = unmarshal_tag(tagptr);
		t += lasttag + 1;
		f = queryfield(st, t);
		if (f == NULL)
			break;
		fill_args(&args, f, ud);
		args.buff = (uint8_t *)buff;
		args.buffsz = size;
		if (f->type & ZPROTO_ARRAY)
			err = decode_array(&args, cb);
		else
			err = decode_field(&args, cb);
		if (err < 0)
			return err;
		assert(err > 0);
		buff += err;
		size -= err;
		lasttag = t;
		tagptr += SIZEOF_TAG;
	}
	return SIZEOF_LEN + len;
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
				if (packsz >= 6 && packsz <= 8) {//6,7,8
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
		return ZPROTO_OOM;
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
	//origin data:0x1,0x2,0x3,0x4,0x5,0x6,0x7,0x8,0x9
	//packed data:0xff,0x1,0x2,0x3,0x4,0x5,0x6,0x7,0x8,0x0,0x1,0x9
	int needn = ((srcsz + 2047) / 2048) * 2 + srcsz + 1;
	if (dstsz < needn)
		return ZPROTO_OOM;
	return pack(src, srcsz, dst, dstsz);
}

int
zproto_unpack(const uint8_t *src, int srcsz, uint8_t *dst, int dstsz)
{
	return unpack(src, srcsz, dst, dstsz);
}

//for debug

static void
dump_struct(struct zproto_struct *st, int level)
{
	int i;
	const char *tab = "\t\t\t\t\t\t\t\t";
	if (st == NULL || level >= 8)
		return ;
	printf("%*.sstruct %s 0x%x {\n", level * 8, tab, st->name, st->tag);
	level = level + 1;
	for (i = 0; i < st->fieldcount; i++) {
		int type;
		struct zproto_field *f;
		f = st->fields[i];
		type = f->type & ZPROTO_TYPE;
		if (type == ZPROTO_STRUCT)
			dump_struct(f->seminfo, level);
	}
	for (i = 0; i < st->fieldcount; i++) {
		int type;
		const char *key = "";
		const char *arr = "";
		struct zproto_field *f;
		f = st->fields[i];
		type = f->type & ZPROTO_TYPE;
		if (f->type & ZPROTO_ARRAY) {
			arr = "[]";
			if (f->mapkey)
				key = f->mapkey->name;
		}
		if (type == ZPROTO_STRUCT) {
			printf("%*.s%s:%s-%d%s%s\n", level * 8, tab,
				f->name, f->seminfo->name, f->tag, arr, key);
		} else {
			printf("%*.s%s:%d-%d%s\n", level * 8, tab,
				f->name, type, f->tag, arr);
		}
	}
	printf("%*.s}\n", (level - 1) * 8, tab);
	return ;
}


void
zproto_dump(struct zproto *z)
{
	int i;
	struct starray *root = z->root;
	for (i = 0; i < root->count; i++)
		dump_struct(root->buf[i], 0);
	return ;
}

