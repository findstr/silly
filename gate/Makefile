CC = gcc
LD = gcc
CCFLAG = -g -Wall
LDFLAG = 
TARGET = gate
SRC = main.c ppoll.c
OBJS = $(patsubst %.c,%.o,$(SRC))

$(TARGET):$(OBJS)
	$(LD) -o $@ $^ $(LDFLAG)

-include $(SRC:.c=.d)

%.d:%c
	@set -e; rm -r $@;\
	$(CC) -MM $< > $@.$$$$;\
	sed 's,\($*\)\.o[ :]*,\1.o $@ : ,g' < $@.$$$$ > $@; \
	rm -f $@.$$$$

%.o:%.c
	$(CC) $(CCFLAG) -c -o $@ $<

clean:
	-rm $(TARGET) $(SRC:.c=.d) $(SRC:.c=.o)
