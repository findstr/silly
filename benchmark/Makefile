.PHONY: all clean

ROOT := ..
SRC_PATH := $(ROOT)/src
LUA_DIR := $(ROOT)/deps/lua
LUA_INC := $(LUA_DIR)
LUA_STATICLIB := $(LUA_DIR)/liblua.a

CC := gcc -std=gnu11
CFLAGS := -O2 -Wall
INCLUDES := -I $(SRC_PATH) -I $(LUA_INC)
LDFLAGS := -lpthread -lm

TARGETS := perf_lock perf_timer

all: $(TARGETS)

$(LUA_STATICLIB):
	make -C $(LUA_DIR) linux MYCFLAGS=-g

perf_lock: perf_lock.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

perf_timer: perf_timer.c $(SRC_PATH)/timer.c $(LUA_STATICLIB)
	$(CC) $(CFLAGS) $(INCLUDES) -o $@ $^ $(LDFLAGS)

clean:
	rm -f $(TARGETS)
