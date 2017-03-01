.PNONY:all

#---------compiler
CC := gcc -std=gnu99
LD := gcc

#---------

TARGET ?= silly

#-----------platform
PLATS=linux macosx
platform:
	@echo "'make PLATFORM' where PLATFORM is one of these:"
	@echo "$(PLATS)"
CCFLAG = -g -O2 -Wall
LDFLAG := -lm -ldl

linux:CCFLAG += -D__linux__
macosx:CCFLAG += -D__macosx__

linux:LDFLAG += -Wl,-E -lrt
macosx:LDFLAG += -Wl,-no_compact_unwind
linux macosx:LDFLAG += -lpthread

linux:SHARED:=--share -fPIC
macosx:SHARED=-dynamiclib -fPIC -Wl,-undefined,dynamic_lookup

linux: PLAT := linux
macosx: PLAT := macosx

#-----------library
LUASTATICLIB=lua/liblua.a

$(LUASTATICLIB):
	make -C lua/ $(PLAT)

#-----------project
TEST_PATH = test
LUACLIB_PATH ?= luaclib
INCLUDE = -I lua/ -I silly-src/
SRC = \
      silly-src/main.c\
      silly-src/silly_socket.c\
      silly-src/silly_queue.c\
      silly-src/silly_worker.c\
      silly-src/silly_timer.c\
      silly-src/silly_run.c\
      silly-src/silly_daemon.c\
      silly-src/silly_env.c\
      silly-src/silly_malloc.c\

OBJS = $(patsubst %.c,%.o,$(SRC))

linux macosx: all

all: \
	$(LUACLIB_PATH)	\
	$(TARGET) \
	$(LUACLIB_PATH)/silly.so \
	$(LUACLIB_PATH)/profiler.so \
	$(LUACLIB_PATH)/log.so \
	$(LUACLIB_PATH)/crypt.so \
	$(LUACLIB_PATH)/netpacket.so \
	$(LUACLIB_PATH)/netstream.so \
	$(LUACLIB_PATH)/netssl.so \
	$(LUACLIB_PATH)/zproto.so \
	$(TEST_PATH)/testaux.so\


$(TARGET):$(OBJS) $(LUASTATICLIB)
	$(LD) -o $@ $^ $(LDFLAG)

$(LUACLIB_PATH):
	mkdir $(LUACLIB_PATH)

$(LUACLIB_PATH)/silly.so: lualib-src/lualib-silly.c
	$(CC) $(CCFLAG) $(INCLUDE) -o $@ $< $(SHARED)
$(LUACLIB_PATH)/netpacket.so: lualib-src/lualib-netpacket.c
	$(CC) $(CCFLAG) $(INCLUDE) -o $@ $< $(SHARED)
$(LUACLIB_PATH)/profiler.so: lualib-src/lualib-profiler.c
	$(CC) $(CCFLAG) $(INCLUDE) -o $@ $< $(SHARED)
$(LUACLIB_PATH)/log.so: lualib-src/lualib-log.c
	$(CC) $(CCFLAG) $(INCLUDE) -o $@ $< $(SHARED)
$(LUACLIB_PATH)/crypt.so: lualib-src/crypt/lualib-crypt.c lualib-src/crypt/lsha1.c lualib-src/crypt/aes.c lualib-src/crypt/sha256.c
	$(CC) $(CCFLAG) $(INCLUDE) -o $@ $^ $(SHARED)
$(LUACLIB_PATH)/netstream.so: lualib-src/lualib-netstream.c
	$(CC) $(CCFLAG) $(INCLUDE) -o $@ $^ $(SHARED)
$(LUACLIB_PATH)/netssl.so: lualib-src/lualib-netssl.c
	$(CC) $(CCFLAG) $(INCLUDE) -o $@ $^ $(SHARED)
$(LUACLIB_PATH)/zproto.so: lualib-src/zproto/lzproto.c lualib-src/zproto/zproto.c
	$(CC) $(CCFLAG) $(INCLUDE) -o $@ $^ $(SHARED)
$(TEST_PATH)/testaux.so: test/testaux.c
	$(CC) $(CCFLAG) $(INCLUDE) -o $@ $^ $(SHARED)

-include $(SRC:.c=.d)

%.d:%.c
	@set -e; rm -f $@;\
	$(CC) $(INCLUDE) -MM $< > $@.$$$$;\
	sed 's,\($*\)\.o[ :]*,\1.o $@ : ,g' < $@.$$$$ > $@; \
	rm -f $@.$$$$

%.o:%.c
	$(CC) $(CCFLAG) $(INCLUDE) -c -o $@ $<

clean:
	-rm $(SRC:.c=.d) $(SRC:.c=.o) *.so $(TARGET)
	-rm -rf $(LUACLIB_PATH)
	-rm $(TEST_PATH)/*.so

cleanall: clean
	make -C lua/ clean

