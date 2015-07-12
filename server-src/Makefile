CC = gcc
LD = gcc
CCFLAG = -g -I ../lua53/ -Wall
LDFLAG = -lm -ldl -Wl,-E  -L ../lua53/ -llua -lrt -lpthread
BUILD_PATH = ..
LUALIB_SRC = ../lualib-src
OBJS = $(patsubst %.c,%.o,$(SRC))

TARGET = server
SRC = main.c event.c timer.c

all:$(BUILD_PATH)/$(TARGET) $(BUILD_PATH)/$(TARGET).so $(BUILD_PATH)/crypt.so

$(BUILD_PATH)/$(TARGET):$(OBJS)
	$(LD) -o $@ $^ $(LDFLAG)

$(BUILD_PATH)/$(TARGET).so:lua-server.c
	gcc $(CCFLAG) -o $@ $< --share -fPIC

$(BUILD_PATH)/crypt.so: $(LUALIB_SRC)/lua-crypt.c $(LUALIB_SRC)/lsha1.c
	gcc $(CCFLAG) -o $@ $^ --share -fPIC


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
