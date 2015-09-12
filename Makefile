CC = gcc -std=gnu99
LD = gcc
INCLUDE = -I lua53/ -I silly-src/
PLATS=linux macosx

BUILD_PATH ?= .
TARGET ?= silly
SRC = silly-src/main.c silly-src/silly_socket.c\
      silly-src/silly_queue.c silly-src/silly_server.c\
      silly-src/silly_worker.c silly-src/silly_timer.c\
      silly-src/silly_run.c silly-src/silly_debug.c\
      silly-src/silly_daemon.c


OBJS = $(patsubst %.c,%.o,$(SRC))

platform:
	@echo "'make PLATFORM' where PLATFORM is one of these:"
	@echo "$(PLATS)"

linux:
	$(MAKE) -C lua53/ linux
	$(MAKE) all \
		CCFLAG="-g -O2 -Wall -D__linux__"\
		LDFLAG="-Wl,-E  -L lua53/ -llua -lm -ldl -lrt -lpthread"\
		SHARED="--share -fPIC"

macosx:
	$(MAKE) -C lua53/ macosx
	$(MAKE) all\
		CCFLAG="-g -Wall -D__macosx__"\
		LDFLAG="-lm -ldl -Wl,-no_compact_unwind  -L lua53/ -llua -lpthread"\
		SHARED="-dynamiclib -fPIC -Wl,-undefined,dynamic_lookup"

all:$(BUILD_PATH)/$(TARGET) silly.so binpacket.so profile.so log.so linepacket.so crypt.so rawpacket.so

$(BUILD_PATH)/$(TARGET):$(OBJS)
	$(LD) -o $@ $^ $(LDFLAG)

silly.so: lualib-src/lualib-silly.c
	$(CC) $(CCFLAG) $(INCLUDE) -o $@ $< $(SHARED) 
binpacket.so: lualib-src/lualib-binpacket.c
	$(CC) $(CCFLAG) $(INCLUDE) -o $@ $< $(SHARED)
profile.so: lualib-src/lualib-profile.c
	$(CC) $(CCFLAG) $(INCLUDE) -o $@ $< $(SHARED)
log.so: lualib-src/lualib-log.c
	$(CC) $(CCFLAG) $(INCLUDE) -o $@ $< $(SHARED)
linepacket.so: lualib-src/lualib-linepacket.c
	$(CC) $(CCFLAG) $(INCLUDE) -o $@ $< $(SHARED)
crypt.so: lualib-src/lualib-crypt.c lualib-src/lsha1.c
	$(CC) $(CCFLAG) $(INCLUDE) -o $@ $^ $(SHARED)
rawpacket.so: lualib-src/lualib-rawpacket.c
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
	$(MAKE) -C lua53/ clean
	-rm $(SRC:.c=.d) $(SRC:.c=.o) *.so silly


