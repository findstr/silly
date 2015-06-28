CC = gcc
LD = gcc
CCFLAG = -g -Wall
LDFLAG = 
TARGET = gate
SRC = main.c ppoll.c server.c socket.c
BUILD_PATH = ..
OBJS = $(patsubst %.c,%.o,$(SRC))

$(BUILD_PATH)/$(TARGET):$(OBJS)
	$(LD) -o $@ $^ $(LDFLAG)

-include $(SRC:.c=.d)

%.d:%.c
	@set -e; rm -f $@;\
	$(CC) -MM $< > $@.$$$$;\
	sed 's,\($*\)\.o[ :]*,\1.o $@ : ,g' < $@.$$$$ > $@; \
	rm -f $@.$$$$

%.o:%.c
	$(CC) $(CCFLAG) -c -o $@ $<

clean:
	-rm $(SRC:.c=.d) $(SRC:.c=.o)
