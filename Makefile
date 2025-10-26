.PHONY: all clean cleanall test testall fmt

INCLUDE :=
#---------

TARGET = silly
OPENSSL ?= ON
TEST ?= OFF
MALLOC ?= jemalloc
SRC_PATH = src
LUACLIB_SRC_PATH = luaclib-src
LUACLIB_PATH ?= luaclib

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
ifeq ($(OPENSSL), ON)
OPENSSLFLAG := -DUSE_OPENSSL -lssl -lcrypto
endif

#####zlib
ZLIB_DIR=deps/zlib
ZLIB_LIB=$(ZLIB_DIR)/libz.a

$(ZLIB_LIB): $(ZLIB_DIR)/Makefile
	make -C $(ZLIB_DIR)

$(ZLIB_DIR)/Makefile: $(ZLIB_DIR)/configure
	cd $(ZLIB_DIR) && ./configure

#-----------project
# Platform directory mapping
ifeq ($(LUA_PLAT),mingw)
PLAT_DIR = win
else
PLAT_DIR = unix
endif

INCLUDE += -I $(LUA_INC) -I $(SRC_PATH) -I $(ZLIB_DIR) -I $(SRC_PATH)/$(PLAT_DIR)
SRC_FILE = \
      main.c \
      api.c \
      socket.c \
      queue.c \
      worker.c \
      timer.c \
      sig.c \
      engine.c \
      daemon.c \
      mem.c \
      log.c \
      trace.c \
      monitor.c \
      message.c \
      force_link.c\

# Combine common and platform-specific sources
COMMON_SRC = $(addprefix $(SRC_PATH)/, $(SRC_FILE))
PLAT_SRC = $(wildcard $(SRC_PATH)/$(PLAT_DIR)/*.c)
SRC = $(COMMON_SRC) $(PLAT_SRC)
OBJS = $(patsubst %.c,%.o,$(SRC))

LIB_SRC = lualib-silly.c \
	lualib-env.c \
	lualib-time.c \
	lualib-metrics.c \
	lualib-logger.c \
	lualib-profiler.c \
	lualib-tls.c \
	lualib-debugger.c \
	lcluster.c \
	lnetstream.c \
	lencoding.c \
	lhive.c \
	lhttp.c \
	lnet.c \
	lsignal.c \
	mysql/lmysql.c \
	lcompress.c \
	adt/lqueue.c

ifeq ($(OPENSSL), ON)
       LIB_SRC += $(patsubst $(LUACLIB_SRC_PATH)/%,%,$(wildcard $(LUACLIB_SRC_PATH)/crypto/*.c))
endif

all: \
	fmt \
	$(TARGET) \
	$(LUACLIB_PATH)/silly.$(SO) \
	$(LUACLIB_PATH)/zproto.$(SO) \
	$(LUACLIB_PATH)/pb.$(SO) \
	$(LUACLIB_PATH)/test.$(SO) \

$(TARGET):$(OBJS) $(LUA_STATICLIB) $(MALLOC_LIB) $(ZLIB_LIB)
	$(LD) -o $@ $^ $(LDFLAGS)

$(LUACLIB_PATH):
	mkdir $(LUACLIB_PATH)

$(LUACLIB_PATH)/silly.$(SO): $(addprefix $(LUACLIB_SRC_PATH)/, $(LIB_SRC)) | $(LUACLIB_PATH)
	$(CC) $(CFLAGS) $(INCLUDE) -I$(LUACLIB_SRC_PATH) -o $@ $^ $(SHARED) $(OPENSSLFLAG) -fvisibility=hidden
$(LUACLIB_PATH)/zproto.$(SO): $(LUACLIB_SRC_PATH)/zproto/lzproto.c $(LUACLIB_SRC_PATH)/zproto/zproto.c | $(LUACLIB_PATH)
	$(CC) $(CFLAGS) $(INCLUDE) -o $@ $^ $(SHARED)
$(LUACLIB_PATH)/pb.$(SO): $(LUACLIB_SRC_PATH)/pb.c | $(LUACLIB_PATH)
	$(CC) $(CFLAGS) $(INCLUDE) -DPB_IMPLEMENTATION -o $@ $^ $(SHARED)
$(LUACLIB_PATH)/test.$(SO): $(LUACLIB_SRC_PATH)/lualib-test.c | $(LUACLIB_PATH)
	$(CC) $(CFLAGS) $(INCLUDE) -o $@ $^ $(SHARED)

.depend:
	@$(CC) $(INCLUDE) -MM $(SRC) 2>/dev/null |\
		sed 's/\([^.]*\).o[: ]/$(SRC_PATH)\/\1.o $@: /g' > $@ || true

-include .depend

%.o:%.c
	$(CC) $(CFLAGS) $(INCLUDE) -fvisibility=hidden -c -o $@ $<

test:
	make TEST=ON MALLOC=glibc all

testall: test
	sh ./test/test.sh

clean:
	-rm .depend
	-rm $(SRC:.c=.o) *.so $(TARGET)
	-rm -rf $(LUACLIB_PATH)
	-rm $(SRC_PATH)/*.lib

cleanall: clean
	make -C $(LUA_DIR) clean
ifneq (,$(wildcard $(JEMALLOC_DIR)/Makefile))
	make -C $(JEMALLOC_DIR) clean && rm $(JEMALLOC_DIR)/Makefile
endif
	-rm $(ZLIB_DIR)/*.a
	-rm $(ZLIB_DIR)/Makefile
	-rm $(ZLIB_DIR)/*.o
	-rm $(ZLIB_DIR)/example
	-rm $(ZLIB_DIR)/example64
	-rm $(ZLIB_DIR)/minigzip
	-rm $(ZLIB_DIR)/minigzip64

fmt:
	-clang-format -style=file -i $(SRC_PATH)/*.h
	-clang-format -style=file -i $(SRC_PATH)/*.c
	-clang-format -style=file -i $(LUACLIB_SRC_PATH)/l*.c
	-clang-format -style=file -i $(LUACLIB_SRC_PATH)/crypto/l*.c

