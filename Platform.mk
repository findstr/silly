CC := gcc -std=gnu99
LD := gcc


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

#enable accept4 should define _GNU_SOURCE
linux:CCFLAG += -DUSE_ACCEPT4
linux:CCFLAG += -D_GNU_SOURCE
