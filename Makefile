.PNONY:all

#---------

TARGET ?= silly

#-----------platform

include Platform.mk

#-----------library

LUASTATICLIB=lua/liblua.a

$(LUASTATICLIB):
	make -C lua/ $(PLAT)

#-----------project
TEST_PATH = test
LUACLIB_PATH ?= luaclib
SRC_PATH = silly-src
INCLUDE = -I lua/ -I $(SRC_PATH)
SRC = \
      $(SRC_PATH)/main.c\
      $(SRC_PATH)/silly_socket.c\
      $(SRC_PATH)/silly_queue.c\
      $(SRC_PATH)/silly_worker.c\
      $(SRC_PATH)/silly_timer.c\
      $(SRC_PATH)/silly_run.c\
      $(SRC_PATH)/silly_daemon.c\
      $(SRC_PATH)/silly_env.c\
      $(SRC_PATH)/silly_malloc.c\
      $(SRC_PATH)/silly_log.c\

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

.depend:
	@$(CC) $(INCLUDE) -MM $(SRC) |\
		sed 's/\([^.]*\).o[: ]/$(SRC_PATH)\/\1.o $@: /g' > $@ || true

-include .depend

%.o:%.c
	$(CC) $(CCFLAG) $(INCLUDE) -c -o $@ $<

clean:
	-rm $(SRC:.c=.o) *.so $(TARGET)
	-rm -rf $(LUACLIB_PATH)
	-rm $(TEST_PATH)/*.so
	-rm .depend

cleanall: clean
	make -C lua/ clean

