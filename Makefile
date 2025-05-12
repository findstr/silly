.PNONY: all clean cleanall testall fmt

INCLUDE :=
#---------

TARGET ?= silly
OPENSSL ?= ON
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
LUACLIB_PATH ?= luaclib
INCLUDE += -I $(LUA_INC) -I $(SRC_PATH) -I $(ZLIB_DIR)
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
      force_link.c\

SRC = $(addprefix $(SRC_PATH)/, $(SRC_FILE))
OBJS = $(patsubst %.c,%.o,$(SRC))

LIB_SRC = lualib-core.c \
	lualib-env.c \
	lualib-time.c \
	lualib-metrics.c \
	lualib-logger.c \
	lualib-profiler.c \
	lualib-netpacket.c \
	lualib-tls.c \
	lualib-debugger.c \
	lnetstream.c \
	lbase64.c \
	lhttp.c \
	mysql/lmysql.c \
	lcompress.c

ifeq ($(OPENSSL), ON)
       LIB_SRC += $(patsubst lualib-src/%,%,$(wildcard lualib-src/crypto/*.c))
endif

all: \
	fmt \
	$(TARGET) \
	$(LUACLIB_PATH)/core.$(SO) \
	$(LUACLIB_PATH)/zproto.$(SO) \
	$(LUACLIB_PATH)/pb.$(SO) \
	$(LUACLIB_PATH)/test.$(SO) \

$(TARGET):$(OBJS) $(LUA_STATICLIB) $(MALLOC_LIB) $(ZLIB_LIB)
	$(LD) -o $@ $^ $(LDFLAGS)

$(LUACLIB_PATH):
	mkdir $(LUACLIB_PATH)

$(LUACLIB_PATH)/core.$(SO): $(addprefix $(LIB_PATH)/, $(LIB_SRC)) | $(LUACLIB_PATH)
	$(CC) $(CFLAGS) $(INCLUDE) -Ilualib-src -o $@ $^ $(SHARED) $(OPENSSLFLAG)
$(LUACLIB_PATH)/zproto.$(SO): $(LIB_PATH)/zproto/lzproto.c $(LIB_PATH)/zproto/zproto.c | $(LUACLIB_PATH)
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
	make TEST=ON MALLOC=glibc all
	./$(TARGET) test/test.lua --lualib_path="test/?.lua"

clean:
	-rm $(SRC:.c=.o) *.so $(TARGET)
	-rm -rf $(LUACLIB_PATH)
	-rm .depend
	-rm $(SRC_PATH)/*.lib
	-rm $(ZLIB_DIR)/*.a
	-rm $(ZLIB_DIR)/Makefile
	-rm $(ZLIB_DIR)/*.o
	-rm $(ZLIB_DIR)/example
	-rm $(ZLIB_DIR)/example64
	-rm $(ZLIB_DIR)/minigzip
	-rm $(ZLIB_DIR)/minigzip64

cleanall: clean
	make -C $(LUA_DIR) clean
ifneq (,$(wildcard $(JEMALLOC_DIR)/Makefile))
	make -C $(JEMALLOC_DIR) clean && rm $(JEMALLOC_DIR)/Makefile
endif

fmt:
	-clang-format -style=file -i silly-src/*.h
	-clang-format -style=file -i silly-src/*.c
	-clang-format -style=file -i lualib-src/l*.c
	-clang-format -style=file -i lualib-src/crypto/l*.c

