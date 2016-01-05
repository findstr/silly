#include <assert.h>
#include <ctype.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <sys/stat.h>
#include <setjmp.h>
#include "zproto.h"

#define CHUNK_SIZE      (512)
#define ZBUFFER_SIZE    (512)
#define TRY(z)          if (setjmp(z->exception) == 0)
#define THROW(z)        longjmp(z->exception, 1)


struct pool_chunk {
        int start;
        int last;
        struct pool_chunk *next;
};

struct zproto_record {
        const char              *name;
        int                     fieldnr;
        struct zproto_record    *next;
        struct zproto_record    *parent;
        struct zproto_record    *child;
        struct zproto_field     *field;
        struct zproto_field     **fieldarray;
};

struct zproto_buffer {
        size_t  cap;
        int     start;
        char    *p;
};

struct zproto {
        int                     linenr;
        const char              *data;
        jmp_buf                 exception;
        struct zproto_record    record;
        struct pool_chunk       *now;
        struct pool_chunk       chunk;
};


static void *
pool_alloc(struct zproto *z, size_t sz)
{
        struct pool_chunk *c = z->now;
        assert(c->next == NULL);
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

static struct zproto_record *
find_record(struct zproto *z, struct zproto_record *proto, const char *name)
{
        struct zproto_record *tmp;
        if (proto == NULL)
                return NULL;
        
        for (tmp = proto->child; tmp; tmp = tmp->next) {
                if (strcmp(tmp->name, name) == 0)
                        return tmp;
        }

        return find_record(z, proto->parent, name);
}

static void
unique_record(struct zproto *z, struct zproto_record *proto, const char *name)
{
        struct zproto_record *tmp;
        for (tmp = proto->child; tmp; tmp = tmp->next) {
                if (strcmp(tmp->name, name) == 0) {
                        fprintf(stderr, "line:%d syntax error:has already define a record named:%s\n", z->linenr, name);
                        THROW(z);
                }
        }

        return;
}

static void
unique_field(struct zproto *z, struct zproto_record *proto, const char *name, int tag)
{
        struct zproto_field *tmp;

        if (tag <= 0) {
                fprintf(stderr, "line:%d syntax error: tag must great then 0\n", z->linenr);
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
strtotype(struct zproto *z, struct zproto_record *proto, const char *type, struct zproto_record **seminfo)
{
        int ztype = 0;
        int sz = strlen(type);
        *seminfo = NULL;
        if (strcmp(&type[sz - 2], "[]") == 0) {
                ztype |= ZPROTO_ARRAY;
                sz -= 2;
        }

        if (strncmp(type, "integer", sz) == 0) {
                ztype |= ZPROTO_INTEGER;
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
                ztype |= ZPROTO_RECORD;
        }

        return ztype;
}

static void
merge_field(struct zproto *z, struct zproto_record *proto)
{
        struct zproto_field *f = proto->field;
        if (proto->fieldnr == 0)
                return ;

        ++proto->fieldnr;
        proto->fieldarray = (struct zproto_field **)pool_alloc(z, proto->fieldnr * sizeof(*f));
        memset(proto->fieldarray, 0, sizeof(*f) * proto->fieldnr);
        while (f) {
                assert(proto->fieldnr > f->tag);
                proto->fieldarray[f->tag] = f;
                f = f->next;
        }

        return ;
}

static void
reverse_field(struct zproto *z, struct zproto_record *proto)
{
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
field(struct zproto *z, struct zproto_record *proto)
{
        int tag;
        int n;
        char field[64];
        char type[64];
        skip_space(z);
        n = sscanf(z->data, ".%64[a-zA-Z0-9]:%64[]a-zA-Z0-9\[]%*[' '|'\t']%d", field, type, &tag);
        if (n != 3) {
                fprintf(stderr, "line:%d synax error: expect field definition, but found:%s\n", z->linenr, z->data);
                THROW(z);
        }

        unique_field(z, proto, field, tag);
        if (tag > proto->fieldnr)
                proto->fieldnr = tag;

        struct zproto_field *f = (struct zproto_field *)pool_alloc(z, sizeof(*f));
        f->next = proto->field;
        proto->field = f;
        f->tag = tag;
        f->name = pool_dupstr(z, field);
        f->type = strtotype(z, proto, type, &f->seminfo);
        return ;
}

static void
record(struct zproto *z, struct zproto_record *proto)
{
        int err;
        char name[64];
        struct zproto_record *new = (struct zproto_record *)pool_alloc(z, sizeof(*new));
        memset(new, 0, sizeof(*new));
        new->next = proto->child;
        new->parent = proto;

        skip_space(z);
        err = sscanf(z->data, "%64s", name);
        if (err != 1) {
                fprintf(stderr, "line:%d syntax error: expect record name\n", z->linenr);
                THROW(z);
        }
        unique_record(z, proto, name);
        new->name = pool_dupstr(z, name);
        next_token(z);

        if (*z->data != '{') {
                fprintf(stderr, "line:%d syntax error: expect '{', but found:%s\n", z->linenr, z->data);
                THROW(z);
        }

        next_token(z);
        
        while (*z->data != '.') {       //child record
                record(z, new);
                skip_space(z);
        }

        while (*z->data == '.') {
                field(z, new);
                next_line(z);
        }

        if (*z->data != '}') {
                fprintf(stderr, "line:%d syntax error: expect '}', but found:%s\n", z->linenr, z->data);
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
                        record(z, &z->record);
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

struct zproto_record *
zproto_query(struct zproto *z, const char *name)
{
        struct zproto_record *r;
        
        for (r = z->record.child; r; r = r->next) {
                if (strcmp(r->name, name) == 0)
                        return r;
        }

        return NULL;
}

struct zproto_field *
zproto_field(struct zproto *z, struct zproto_record *proto)
{
        assert(z);
        return proto->field;
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

//////////encode/decode

void
zproto_buffer_drop(struct zproto_buffer *zb)
{
        free(zb->p);
        free(zb);

        return ;
}

void
zproto_buffer_fill(struct zproto_buffer *zb, int32_t pos, int32_t val)
{
        assert(pos < zb->cap);
        *(int32_t *)&zb->p[pos] = val;
        return ;
}

struct zproto_buffer *
zproto_encode_begin(int32_t protocol)
{
        struct zproto_buffer *zb = (struct zproto_buffer *)malloc(sizeof(*zb));
        memset(zb, 0 , sizeof(*zb));
        zb->cap = ZBUFFER_SIZE;
        zb->p = (char *)malloc(zb->cap);
        *(int32_t *)(zb->p) = protocol;
        zb->start += sizeof(int32_t);
        return zb;
}

char *
zproto_encode_end(struct zproto_buffer *zb, int *sz)
{
        char *p = zb->p;
        *sz = zb->start;
        free(zb);
        return p;
}

static void
resize_buffer(struct zproto_buffer *zb, int sz)
{
        if (zb->cap >= (sz + zb->start))
                return ;

        zb->cap *= 2;
        zb->p = realloc(zb->p, zb->cap);
        assert(zb->cap >= sz);

        return ;
}

int32_t
zproto_encode_record(struct zproto_buffer *zb)
{
        resize_buffer(zb, sizeof(int32_t));
        int32_t nr = zb->start;
        zb->start += sizeof(int32_t);
        return nr;
}

void
zproto_encode_tag(struct zproto_buffer *zb, struct zproto_field *last, struct zproto_field *field, int32_t count)
{
        int lasttag = last ? last->tag : 0;
        int skip;

        resize_buffer(zb, sizeof(int32_t));
        skip = field->tag - lasttag - 1;
        assert(skip >= 0);

        *(int32_t *)&zb->p[zb->start] = skip;
        zb->start += sizeof(int32_t);

        if ((field->type & ZPROTO_ARRAY) == 0)
                return ;

        //tag of array need count
        resize_buffer(zb, sizeof(int32_t));
        int32_t *nr = (int32_t *)&zb->p[zb->start];
        zb->start += sizeof(int32_t);
        *nr = count;
        return ;
}

void 
zproto_encode(struct zproto_buffer *zb, struct zproto_field *last, struct zproto_field *field, const char *data, int32_t sz)
{
        if ((field->type & ZPROTO_ARRAY) == 0) {
                zproto_encode_tag(zb, last, field, 0);
        }


        if ((field->type & ZPROTO_TYPE) == ZPROTO_INTEGER) {
                resize_buffer(zb, sizeof(int32_t));
                assert(sz == sizeof(int32_t));
                *(int32_t *)&zb->p[zb->start] = *(int32_t *)data;
                zb->start += sizeof(int32_t);
        } else if ((field->type & ZPROTO_TYPE) == ZPROTO_STRING) {
                resize_buffer(zb, sizeof(int32_t) + sz);
                *(int32_t *)&zb->p[zb->start] = sz;
                zb->start += sizeof(int32_t);
                memcpy(&zb->p[zb->start], data, sz);
                zb->start += sz;
        }

        return ;
}

int32_t zproto_decode_protocol(char *buff, int sz)
{
        if (sz < sizeof(int32_t))
                return -1;
        return *(int32_t *)buff;
}

struct zproto_buffer *
zproto_decode_begin(char *buff, int sz)
{
        struct zproto_buffer *zb = (struct zproto_buffer *)malloc(sizeof(*zb));
        memset(zb, 0 , sizeof(*zb));
        zb->cap = sz;
        zb->p = buff;
        zb->start += sizeof(int32_t);   //skip protocol field
        return zb;
}

void
zproto_decode_end(struct zproto_buffer *zb)
{
        free(zb->p);
        free(zb);
        
        return ;
}

int32_t
zproto_decode_record(struct zproto_buffer *zb)
{
        int32_t nr;
        if (zb->start + sizeof(int32_t) >= zb->cap)
                return 0;
        nr = *(int32_t *)&zb->p[zb->start];
        zb->start += sizeof(int32_t);
        return nr;
}

struct zproto_field *
zproto_decode_tag(struct zproto_buffer *zb, struct zproto_field *last, struct zproto_record *proto, int32_t *sz)
{
        struct zproto_field *field;
        int32_t ltag = last ? last->tag : 0;
        int32_t skip = *(int32_t *)&zb->p[zb->start];
        zb->start += sizeof(int32_t);
        ltag += skip + 1;
        if (ltag >= proto->fieldnr)
                return NULL;

        field = proto->fieldarray[ltag];

        if (field->type & ZPROTO_ARRAY) {
                *sz = *(int32_t *)&zb->p[zb->start];
                zb->start += sizeof(int32_t);
        } else {
                *sz = 0;
        }

        return field;
}

int
zproto_decode(struct zproto_buffer *zb, struct zproto_field *field, char **data, int32_t *sz)
{
        if (zb->start + sizeof(int32_t) > zb->cap)
                return -1;

        if ((field->type & ZPROTO_TYPE) == ZPROTO_INTEGER) {
                *sz = sizeof(int32_t);
                *data = &zb->p[zb->start];
                zb->start += sizeof(int32_t);
        } else if ((field->type & ZPROTO_TYPE) == ZPROTO_STRING) {
                *sz = *(int32_t *)&zb->p[zb->start];
                zb->start += sizeof(int32_t);
                if (zb->start + sizeof(int32_t) > zb->cap)
                        return -1;

                *data = &zb->p[zb->start];
                zb->start += *sz;
        }

        return 0;
}


//for debug

static void
dump_record(struct zproto_record *proto)
{
        struct zproto_record *tr;
        struct zproto_field *tf;
        if (proto == NULL)
                return ;

        printf("=====record:%s\n", proto->name);
        printf("-----field:\n");
        for (tf = proto->field; tf; tf = tf->next) {
                if (tf->type & ZPROTO_ARRAY)
                        printf("array:");
                if ((tf->type & ZPROTO_TYPE) == ZPROTO_RECORD)
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
        struct zproto_record *r = z->record.child;
        dump_record(r);
}

