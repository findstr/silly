CC = gcc
LD = gcc
CCFLAG = -g -I ../lua53/ -Wall
LDFLAG = -lm -ldl -Wl,-E  -L ../lua53/ -llua
BUILD_PATH = ..
OBJS = $(patsubst %.c,%.o,$(SRC))

TARGET = server
SRC = main.c socket.c

all:$(BUILD_PATH)/$(TARGET) $(BUILD_PATH)/$(TARGET).so

$(BUILD_PATH)/$(TARGET):$(OBJS)
	$(LD) -o $@ $^ $(LDFLAG)

$(BUILD_PATH)/$(TARGET).so:lua-server.c
	gcc $(CCFLAG) -o $@ $< --share -fPIC

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
