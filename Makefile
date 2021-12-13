.PNONY:all
INCLUDE :=
#---------

TARGET ?= silly
TLS ?= ON

#-----------platform

include Platform.mk

linux macosx: all

#-----------library

#lua

LUA_DIR=deps/lua
LUA_INC=$(LUA_DIR)
LUA_STATICLIB=$(LUA_DIR)/liblua.a

$(LUA_STATICLIB):
	make -C $(LUA_DIR) $(PLAT) MYCFLAGS=-g

#malloc lib select
MALLOC_NAME=jemalloc
ifeq ($(MALLOC_NAME), jemalloc)
JEMALLOC_DIR=deps/jemalloc
JEMALLOC_INC=$(JEMALLOC_DIR)/include
JEMALLOC_STATICLIB=$(JEMALLOC_DIR)/lib/libjemalloc.a

$(JEMALLOC_STATICLIB):$(JEMALLOC_DIR)/Makefile
	make -C $(JEMALLOC_DIR)

$(JEMALLOC_DIR)/Makefile:$(JEMALLOC_DIR)/autogen.sh
	cd $(JEMALLOC_DIR)&&\
		./autogen.sh --with-jemalloc-prefix=je_
$(JEMALLOC_DIR)/autogen.sh:
	git submodule update --init
jemalloc:$(JEMALLOC_STATICLIB)
INCLUDE += -I $(JEMALLOC_INC)
MALLOC_STATICLIB := $(JEMALLOC_STATICLIB)
all:jemalloc
else
CCFLAG += -DDISABLE_JEMALLOC
MALLOC_STATICLIB :=
endif

#tls disable
ifeq ($(TLS), ON)
TLSFLAG := -DUSE_OPENSSL -lssl -lcrypto
endif


#-----------project
LUACLIB_PATH ?= luaclib
SRC_PATH = silly-src
LIB_PATH = lualib-src
INCLUDE += -I $(LUA_INC) -I $(SRC_PATH)
SRC_FILE = \
      main.c \
      silly_socket.c \
      silly_queue.c \
      silly_worker.c \
      silly_timer.c \
      silly_run.c \
      silly_daemon.c \
      silly_env.c \
      silly_malloc.c \
      silly_log.c \
      silly_monitor.c \

SRC = $(addprefix $(SRC_PATH)/, $(SRC_FILE))
OBJS = $(patsubst %.c,%.o,$(SRC))

LIB_SRC = lualib-silly.c \
	  lualib-profiler.c \
	  lualib-netstream.c \
	  lualib-netpacket.c \
	  lualib-tls.c \
	  lualib-crypto.c lsha1.c aes.c sha256.c md5.c\
	  lualib-debugger.c\

all: \
	$(TARGET) \
	$(LUACLIB_PATH)/sys.so \
	$(LUACLIB_PATH)/zproto.so \
	$(LUACLIB_PATH)/http2.so \
	$(LUACLIB_PATH)/test.so \

$(TARGET):$(OBJS) $(LUA_STATICLIB) $(MALLOC_STATICLIB)
	$(LD) -o $@ $^ $(LDFLAG)

$(LUACLIB_PATH):
	mkdir $(LUACLIB_PATH)

$(LUACLIB_PATH)/sys.so: $(addprefix $(LIB_PATH)/, $(LIB_SRC)) | $(LUACLIB_PATH)
	$(CC) $(CCFLAG) $(INCLUDE) -o $@ $^ $(SHARED) $(TLSFLAG)
$(LUACLIB_PATH)/zproto.so: $(LIB_PATH)/zproto/lzproto.c $(LIB_PATH)/zproto/zproto.c | $(LUACLIB_PATH)
	$(CC) $(CCFLAG) $(INCLUDE) -o $@ $^ $(SHARED)
$(LUACLIB_PATH)/http2.so: $(LIB_PATH)/lualib-http2.c | $(LUACLIB_PATH)
	$(CC) $(CCFLAG) $(INCLUDE) -o $@ $^ $(SHARED)
$(LUACLIB_PATH)/test.so: $(LIB_PATH)/lualib-test.c | $(LUACLIB_PATH)
	$(CC) $(CCFLAG) $(INCLUDE) -o $@ $^ $(SHARED)

.depend:
	@$(CC) $(INCLUDE) -MM $(SRC) 2>/dev/null |\
		sed 's/\([^.]*\).o[: ]/$(SRC_PATH)\/\1.o $@: /g' > $@ || true

-include .depend

%.o:%.c
	$(CC) $(CCFLAG) $(INCLUDE) -c -o $@ $<

test: CCFLAG += -fsanitize=address -fno-omit-frame-pointer -DHTTP2_HEADER_SIZE=4096
test: LDFLAG += -fsanitize=address -fno-omit-frame-pointer
test: $(PLATS)
	./$(TARGET) test/test.conf

clean:
	-rm $(SRC:.c=.o) *.so $(TARGET)
	-rm -rf $(LUACLIB_PATH)
	-rm .depend

cleanall: clean
	make -C $(LUA_DIR) clean
ifneq (,$(wildcard $(JEMALLOC_DIR)/Makefile))
	cd $(JEMALLOC_DIR)&&make clean&&rm Makefile
endif

