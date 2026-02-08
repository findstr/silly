.PHONY: all clean cleanall test testall fmt

INCLUDE :=
#---------

TARGET = silly
OPENSSL ?= ON
SNAPPY ?= OFF
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

#####zlib
ZLIB_DIR=deps/zlib
ZLIB_LIB=$(ZLIB_DIR)/libz.a

$(ZLIB_LIB): $(ZLIB_DIR)/Makefile
	make -C $(ZLIB_DIR)

$(ZLIB_DIR)/Makefile: $(ZLIB_DIR)/configure
	cd $(ZLIB_DIR) && ./configure

#####lz4
LZ4_DIR=deps/lz4
LZ4_OBJ=$(LZ4_DIR)/lz4.o
INCLUDE += -I $(LZ4_DIR)

$(LZ4_OBJ): $(LZ4_DIR)/lz4.c
	$(CC) $(CFLAGS) -c -o $@ $<

#####snappy
SNAPPY_DIR=deps/snappy
ifeq ($(SNAPPY), ON)
CFLAGS += -DUSE_SNAPPY
INCLUDE += -I $(SNAPPY_DIR)
LDFLAGS += -lstdc++
SNAPPY_BUILD_DIR=$(SNAPPY_DIR)/build
SNAPPY_LIB=$(SNAPPY_BUILD_DIR)/libsnappy.a

$(SNAPPY_LIB): $(SNAPPY_BUILD_DIR)/Makefile
	make -C $(SNAPPY_BUILD_DIR)

$(SNAPPY_BUILD_DIR)/Makefile: $(SNAPPY_DIR)/CMakeLists.txt
	mkdir -p $(SNAPPY_BUILD_DIR) && \
		cd $(SNAPPY_BUILD_DIR) && \
		cmake .. $(CMAKE_GENERATOR) -DCMAKE_BUILD_TYPE=Release \
			-DSNAPPY_BUILD_TESTS=OFF \
			-DSNAPPY_BUILD_BENCHMARKS=OFF \
			-DBUILD_SHARED_LIBS=OFF

$(SNAPPY_DIR)/CMakeLists.txt:
	git submodule update --init
endif

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

LIB_SRC = lsilly.c \
	lenv.c \
	ltime.c \
	lmetrics.c \
	llogger.c \
	lperf.c \
	ltls.c \
	ldebugger.c \
	ltrace.c\
	lcluster.c \
	lencoding.c \
	lhive.c \
	lhttp.c \
	lnet.c \
	lsignal.c \
	mysql/lmysql.c \
	lcompress.c \
	adt/lqueue.c \
	adt/lbuffer.c

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

$(TARGET):$(OBJS) $(LUA_STATICLIB) $(MALLOC_LIB) $(ZLIB_LIB) $(LZ4_OBJ) $(SNAPPY_LIB)
	$(LD) -o $@ $^ $(LDFLAGS)

$(LUACLIB_PATH):
	mkdir $(LUACLIB_PATH)

$(LUACLIB_PATH)/silly.$(SO): $(addprefix $(LUACLIB_SRC_PATH)/, $(LIB_SRC)) | $(LUACLIB_PATH)
	$(CC) $(CFLAGS) $(INCLUDE) -I$(LUACLIB_SRC_PATH) -o $@ $^ $(SHARED) -fvisibility=hidden
$(LUACLIB_PATH)/zproto.$(SO): $(LUACLIB_SRC_PATH)/zproto/lzproto.c $(LUACLIB_SRC_PATH)/zproto/zproto.c | $(LUACLIB_PATH)
	$(CC) $(CFLAGS) $(INCLUDE) -o $@ $^ $(SHARED)
$(LUACLIB_PATH)/pb.$(SO): $(LUACLIB_SRC_PATH)/pb.c | $(LUACLIB_PATH)
	$(CC) $(CFLAGS) $(INCLUDE) -DPB_IMPLEMENTATION -o $@ $^ $(SHARED)
$(LUACLIB_PATH)/test.$(SO): $(LUACLIB_SRC_PATH)/ltest.c | $(LUACLIB_PATH)
	$(CC) $(CFLAGS) $(INCLUDE) -o $@ $^ $(SHARED)

.depend:
	@$(CC) $(INCLUDE) -MM $(SRC) 2>/dev/null |\
		sed 's/\([^.]*\).o[: ]/$(SRC_PATH)\/\1.o $@: /g' > $@ || true

-include .depend

%.o:%.c
	$(CC) $(CFLAGS) $(INCLUDE) -fvisibility=hidden -c -o $@ $<

test:
	make TEST=ON MALLOC=glibc SNAPPY=ON all

testall: test
	sh ./test/test.sh

clean:
	-rm .depend
	-rm $(SRC:.c=.o) *.so $(TARGET)
	-rm -rf $(LUACLIB_PATH)
	-rm $(SRC_PATH)/*.lib
	-rm $(LZ4_DIR)/lz4.o

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
	-git -C $(ZLIB_DIR) checkout zconf.h
	-rm -rf $(SNAPPY_DIR)/build

fmt:
	-clang-format -style=file -i $(SRC_PATH)/*.h
	-clang-format -style=file -i $(SRC_PATH)/*.c
	-clang-format -style=file -i $(LUACLIB_SRC_PATH)/l*.c
	-clang-format -style=file -i $(LUACLIB_SRC_PATH)/crypto/l*.c
