#ifndef SILLY_ADT_STACK_H
#define SILLY_ADT_STACK_H

#include <stdlib.h>
#include <assert.h>
#include "silly.h"

struct stack {
    int *data;
    int size;
    int capacity;
};

static inline void stack_init(struct stack *s)
{
    s->data = NULL;
    s->size = 0;
    s->capacity = 0;
}

static inline void stack_reserve(struct stack *s, int new_cap)
{
    if (new_cap <= s->capacity)
        return;
    s->data = (int *)silly_realloc(s->data, new_cap * sizeof(int));
    s->capacity = new_cap;
}

static inline void stack_push(struct stack *s, int value)
{
    if (s->size >= s->capacity) {
        int new_cap = (s->capacity == 0) ? 32 : s->capacity * 2;
        stack_reserve(s, new_cap);
    }
    s->data[s->size++] = value;
}

static inline int stack_pop(struct stack *s)
{
    assert(s->size > 0);
    return s->data[--s->size];
}

static inline int stack_empty(struct stack *s)
{
    return s->size == 0;
}

static inline void stack_destroy(struct stack *s)
{
    if (s->data) {
        silly_free(s->data);
        s->data = NULL;
    }
    s->size = 0;
    s->capacity = 0;
}

#endif