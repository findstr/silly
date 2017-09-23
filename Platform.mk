.PHONY:target

uname := $(shell sh -c 'uname -s 2>/dev/null || echo not')

CC := gcc -std=gnu99
LD := gcc

ifeq ($(uname),Linux)
target:linux
else
ifeq ($(uname),Darwin)
target:macosx
endif
endif


PLATS=linux macosx
platform:
	@echo "'make PLATFORM' where PLATFORM is one of these:"
	@echo "$(PLATS)"
CCFLAG = -g -O2 -Wall -Wextra
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

