.PNONY: all clean cleanall testall fmt

INCLUDE :=
#---------

TARGET ?= silly
TLS ?= ON
TEST ?= OFF
MALLOC ?= jemalloc
SRC_PATH = silly-src
LIB_PATH = lualib-src

#-----------platform

include Platform.mk

all:
#-----------library

#####lua
LUA_DIR=deps/lua
LUA_INC=$(LUA_DIR)
LUA_STATICLIB=$(LUA_DIR)/liblua.a

$(LUA_STATICLIB):
	make -C $(LUA_DIR) $(LUA_PLAT) MYCFLAGS=-g

#####malloc lib select
ifeq ($(MALLOC), jemalloc)
JEMALLOC_DIR=deps/jemalloc
JEMALLOC_INC=$(JEMALLOC_DIR)/include
MALLOC_LIB:=$(JEMALLOC_DIR)/lib/$(LIBPREFIX)jemalloc.$(A)

$(MALLOC_LIB):$(JEMALLOC_DIR)/Makefile
	make -C $(JEMALLOC_DIR)

$(JEMALLOC_DIR)/Makefile:$(JEMALLOC_DIR)/autogen.sh
	cd $(JEMALLOC_DIR)&&\
		./autogen.sh --with-jemalloc-prefix=je_
$(JEMALLOC_DIR)/autogen.sh:
	git submodule update --init
INCLUDE += -I $(JEMALLOC_INC)
all:$(MALLOC_LIB)
else
CFLAGS += -DDISABLE_JEMALLOC
MALLOC_LIB :=
endif

#tls disable
ifeq ($(TLS), ON)
TLSFLAG := -DUSE_OPENSSL -lssl -lcrypto
endif


#-----------project
LUACLIB_PATH ?= luaclib
INCLUDE += -I $(LUA_INC) -I $(SRC_PATH)
SRC_FILE = \
      main.c \
      silly_socket.c \
      silly_queue.c \
      silly_worker.c \
      silly_timer.c \
      silly_signal.c \
      silly_run.c \
      silly_daemon.c \
      silly_malloc.c \
      silly_log.c \
      silly_trace.c \
      silly_monitor.c \
      pipe.c \
      event.c \

SRC = $(addprefix $(SRC_PATH)/, $(SRC_FILE))
OBJS = $(patsubst %.c,%.o,$(SRC))

LIB_SRC = lualib-core.c \
	  lualib-env.c \
	  lualib-time.c \
	  lualib-metrics.c \
	  lualib-logger.c \
	  lualib-profiler.c \
	  lualib-netstream.c \
	  lualib-netpacket.c \
	  lualib-tls.c \
	  lualib-crypto.c lsha1.c aes.c sha256.c md5.c\
	  lualib-debugger.c\

all: \
	fmt \
	$(TARGET) \
	$(LUACLIB_PATH)/core.$(SO) \
	$(LUACLIB_PATH)/zproto.$(SO) \
	$(LUACLIB_PATH)/http2.$(SO) \
	$(LUACLIB_PATH)/pb.$(SO) \
	$(LUACLIB_PATH)/test.$(SO) \

$(TARGET):$(OBJS) $(LUA_STATICLIB) $(MALLOC_LIB)
	$(LD) -o $@ $^ $(LDFLAGS)

$(LUACLIB_PATH):
	mkdir $(LUACLIB_PATH)

$(LUACLIB_PATH)/core.$(SO): $(addprefix $(LIB_PATH)/, $(LIB_SRC)) | $(LUACLIB_PATH)
	$(CC) $(CFLAGS) $(INCLUDE) -o $@ $^ $(SHARED) $(TLSFLAG)
$(LUACLIB_PATH)/zproto.$(SO): $(LIB_PATH)/zproto/lzproto.c $(LIB_PATH)/zproto/zproto.c | $(LUACLIB_PATH)
	$(CC) $(CFLAGS) $(INCLUDE) -o $@ $^ $(SHARED)
$(LUACLIB_PATH)/http2.$(SO): $(LIB_PATH)/lualib-http2.c | $(LUACLIB_PATH)
	$(CC) $(CFLAGS) $(INCLUDE) -o $@ $^ $(SHARED)
$(LUACLIB_PATH)/pb.$(SO): $(LIB_PATH)/pb.c | $(LUACLIB_PATH)
	$(CC) $(CFLAGS) $(INCLUDE) -DPB_IMPLEMENTATION -o $@ $^ $(SHARED)
$(LUACLIB_PATH)/test.$(SO): $(LIB_PATH)/lualib-test.c | $(LUACLIB_PATH)
	$(CC) $(CFLAGS) $(INCLUDE) -o $@ $^ $(SHARED)

.depend:
	@$(CC) $(INCLUDE) -MM $(SRC) 2>/dev/null |\
		sed 's/\([^.]*\).o[: ]/$(SRC_PATH)\/\1.o $@: /g' > $@ || true

-include .depend

%.o:%.c
	$(CC) $(CFLAGS) $(INCLUDE) -c -o $@ $<

testall:
	make TEST=ON all
	./$(TARGET) test/test.lua --lualib_path="test/?.lua"

clean:
	-rm $(SRC:.c=.o) *.so $(TARGET)
	-rm -rf $(LUACLIB_PATH)
	-rm .depend
	-rm $(SRC_PATH)/*.lib

cleanall: clean
	make -C $(LUA_DIR) clean
ifneq (,$(wildcard $(JEMALLOC_DIR)/Makefile))
	make -C $(JEMALLOC_DIR) clean rm $(JEMALLOC_DIR)/Makefile
endif

fmt:
	-clang-format -i silly-src/*.h
	-clang-format -i silly-src/*.c
	-clang-format -i lualib-src/lua*.c

