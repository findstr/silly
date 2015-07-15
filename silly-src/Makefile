CC = gcc
LD = gcc
INCLUDE = -I ../lua53/ 
PLATS=linux macosx

BUILD_PATH = .
LUALIB_SRC = ../lualib-src

TARGET = silly
SRC = main.c silly_socket.c silly_queue.c silly_server.c silly_worker.c silly_timer.c
OBJS = $(patsubst %.c,%.o,$(SRC))

platform:
	@echo "'make PLATFORM' where PLATFORM is one of these:"
	@echo "$(PLATS)"

linux:
	$(MAKE) all \
		CCFLAG="-g -Wall -D__linux__"\
		LDFLAG="-lm -ldl -Wl,-E  -L ../lua53/ -llua -lrt -lpthread"\
		SHARED="--share -fPIC"\

macosx:
	$(MAKE) all\
		CCFLAG="-g -Wall -D__macosx__"\
		LDFLAG="-lm -ldl -Wl,-no_compact_unwind  -L ../lua53/ -llua -lpthread"\
		SHARED="-dynamiclib -fPIC -Wl,-undefined,dynamic_lookup"

all:$(BUILD_PATH)/$(TARGET) server.so rawpacket.so

$(BUILD_PATH)/$(TARGET):$(OBJS)
	$(LD) -o $@ $^ $(LDFLAG)

server.so: lualib-server.c
	$(CC) $(CCFLAG) $(INCLUDE) -o $@ $< $(SHARED) 
rawpacket.so: lualib-rawpacket.c
	$(CC) $(CCFLAG) $(INCLUDE) -o $@ $< $(SHARED)

-include $(SRC:.c=.d)

%.d:%.c
	@set -e; rm -f $@;\
	$(CC) $(INCLUDE) -MM $< > $@.$$$$;\
	sed 's,\($*\)\.o[ :]*,\1.o $@ : ,g' < $@.$$$$ > $@; \
	rm -f $@.$$$$

%.o:%.c
	$(CC) $(CCFLAG) $(INCLUDE) -c -o $@ $<

clean:
	-rm $(SRC:.c=.d) $(SRC:.c=.o) *.so silly


