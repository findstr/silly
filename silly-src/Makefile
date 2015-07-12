CC = gcc
LD = gcc
CCFLAG = -g -I ../lua53/ -Wall
LDFLAG = -lm -ldl -Wl,-E  -L ../lua53/ -llua -lrt -lpthread
BUILD_PATH = .
LUALIB_SRC = ../lualib-src
OBJS = $(patsubst %.c,%.o,$(SRC))

TARGET = silly
SRC = main.c silly_socket.c silly_queue.c silly_server.c silly_worker.c

all:$(BUILD_PATH)/$(TARGET) server.so rawpacket.so

$(BUILD_PATH)/$(TARGET):$(OBJS)
	$(LD) -o $@ $^ $(LDFLAG)

server.so: lualib-server.c
	$(CC) $(CCFLAG) -o $@ $< --share -fPIC

rawpacket.so: lualib-rawpacket.c
	$(CC) $(CCFLAG) -o $@ $< --share -fPIC

-include $(SRC:.c=.d)

%.d:%.c
	@set -e; rm -f $@;\
	$(CC) -MM $< > $@.$$$$;\
	sed 's,\($*\)\.o[ :]*,\1.o $@ : ,g' < $@.$$$$ > $@; \
	rm -f $@.$$$$

%.o:%.c
	$(CC) $(CCFLAG) -c -o $@ $<

clean:
	-rm $(SRC:.c=.d) $(SRC:.c=.o) *.so silly
